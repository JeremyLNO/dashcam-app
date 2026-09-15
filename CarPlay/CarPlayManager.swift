#if canImport(CarPlay)
import CarPlay
#endif
import Combine
import Foundation

/// The CarPlay screen: a remote control and a dashboard, and nothing else.
///
/// There is no navigation here and there never will be — the driver keeps using Maps, Waze
/// or Google Maps. What the car's screen is for is the handful of things a driver must be
/// able to do without reaching for the phone, and the handful of facts they must be able to
/// read without looking twice.
///
/// **What is on the screen is what the app can prove.** The first version reported
/// `RECORDING` and a ticking duration for a drive that was writing nothing at all, because
/// nothing on that screen came from the footage — it came from a flag. So the status line
/// now answers to the camera, the clip counter is the number of files actually closed on
/// disk, and when the cameras cannot run the screen says which gesture fixes it instead of
/// offering a button that cannot work.
///
/// The whole feature is optional. Without the `carplay-driving-task` entitlement the
/// template scene is simply never created by iOS, and nothing in the phone app notices.
@MainActor
final class CarPlayManager: ObservableObject {
    @Published private(set) var isConnected = false

    private let recording: RecordingManager
    private let capture: CaptureManager
    private let storage: StorageManager
    private let dimmer: ScreenDimmer
    /// Asked when the CarPlay screen connects, so the same preference governs both paths.
    var shouldAutoStartOnConnect: () -> Bool = { false }
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    #if canImport(CarPlay)
    private var interfaceController: CPInterfaceController?
    private var template: CPInformationTemplate?
    #endif

    init(
        recording: RecordingManager,
        capture: CaptureManager,
        storage: StorageManager,
        dimmer: ScreenDimmer
    ) {
        self.recording = recording
        self.capture = capture
        self.storage = storage
        self.dimmer = dimmer
    }

    // MARK: - Scene lifecycle

    #if canImport(CarPlay)
    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        isConnected = true

        let template = makeTemplate()
        self.template = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        observeState()
        Log.carplay.info("CarPlay connected")

        if shouldAutoStartOnConnect(), !recording.isRecording {
            Task { @MainActor in await recording.start() }
        }
    }

    func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancellables.removeAll()
        interfaceController = nil
        template = nil
        isConnected = false
        Log.carplay.info("CarPlay disconnected")
    }

    // MARK: - Template

    private func makeTemplate() -> CPInformationTemplate {
        CPInformationTemplate(
            title: L10n.t("carplay.title"),
            // Two columns rather than one: the single column left two thirds of a very wide
            // screen empty and pushed every figure into a narrow strip on the left.
            layout: .twoColumn,
            items: currentItems(),
            actions: currentActions()
        )
    }

    // MARK: - What the screen says

    /// The status line, which is the one thing a driver reads at a glance — so it is the
    /// one line that must never be a guess.
    private func statusItem() -> CPInformationItem {
        if recording.isRecording {
            return CPInformationItem(title: L10n.t("carplay.status"), detail: L10n.t("carplay.recording"))
        }
        let detail = CarPlayDashboard.stoppedStatusKey(readiness: RecordingReadiness.assess(capture.status),
                                                       interruption: capture.status.interruption)
        return CPInformationItem(title: L10n.t("carplay.status"), detail: L10n.t(detail))
    }

    private func currentItems() -> [CPInformationItem] {
        var items = [statusItem()]

        if recording.isRecording {
            items.append(CPInformationItem(title: L10n.t("carplay.duration"), detail: Format.duration(recording.elapsed)))
            // The count of files actually closed on disk. It is the only figure here that
            // footage has to exist for — a drive writing nothing sits at zero while the
            // duration climbs, and that disagreement is the whole point of showing it.
            items.append(CPInformationItem(
                title: L10n.t("carplay.clips"),
                detail: "\(recording.segmentCount)"
            ))
        }

        items.append(CPInformationItem(
            title: L10n.t("carplay.cameras"),
            detail: L10n.t(CarPlayDashboard.camerasKey(status: capture.status))
        ))
        items.append(CPInformationItem(
            title: L10n.t("carplay.storage"),
            detail: Format.bytes(storage.snapshot.freeBytes)
        ))

        if recording.isRecording,
           let confirmation = recording.lastProtectionConfirmation,
           Date().timeIntervalSince(confirmation) < 6 {
            items.append(CPInformationItem(title: L10n.t("carplay.protected"), detail: L10n.t("carplay.protected.detail")))
        }
        return items
    }

    /// At most three, which is the template's limit and also as many as anyone should be
    /// asked to choose between while driving.
    private func currentActions() -> [CPTextButton] {
        guard recording.isRecording else {
            // No Start button when starting cannot work: a button that does nothing is
            // worse than none, because the driver presses it and believes it worked. The
            // screen is watching the camera, so it comes back on its own.
            guard RecordingReadiness.assess(capture.status).isReady else { return [] }
            return [
                CPTextButton(title: L10n.t("carplay.start"), textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in await self?.recording.start() }
                }
            ]
        }

        return [
            CPTextButton(title: L10n.t("carplay.stop"), textStyle: .cancel) { [weak self] _ in
                Task { @MainActor in await self?.recording.stop() }
            },
            CPTextButton(title: L10n.t("carplay.protect"), textStyle: .confirm) { [weak self] _ in
                Task { @MainActor in self?.protectFromCarPlay() }
            },
            CPTextButton(
                title: L10n.t(dimmer.isDiscreet ? "carplay.screen.wake" : "carplay.screen.dim"),
                textStyle: .normal
            ) { [weak self] _ in
                Task { @MainActor in self?.toggleDiscreet() }
            },
        ]
    }

    private func protectFromCarPlay() {
        recording.protectNow(origin: .carPlay)
        refresh()
    }

    /// The phone is in its cradle and the driver's hands are on the wheel; this is the
    /// gesture the car's screen exists for. It obeys the same rule as the moon button on
    /// the phone, because the rule lives in `ScreenDimmer` and not at the call sites.
    private func toggleDiscreet() {
        if dimmer.isDiscreet {
            dimmer.exit()
        } else {
            dimmer.enter(whileRecording: recording.isRecording)
        }
        refresh()
    }

    // MARK: - Keeping it current

    private func observeState() {
        // Three publishers, one refresh. The capture status is the newest of the three and
        // the one that was missing: without it, a screen showing « Unlock the iPhone »
        // stayed that way after the phone was unlocked.
        recording.$isRecording
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
        capture.$status
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
        dimmer.$isDiscreet
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)

        // The duration and the clip counter have to tick, but only while there is
        // something to tick.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording.isRecording else { return }
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard let template else { return }
        template.items = currentItems()
        template.actions = currentActions()
    }
    #else
    func disconnect() { isConnected = false }
    #endif
}

/// What the car's screen says, as plain decisions over the capture state.
///
/// Kept apart from the template so it can be tested: `CPInformationTemplate` cannot be
/// built on a machine without CarPlay, and these are exactly the lines that were wrong.
enum CarPlayDashboard {
    /// The status detail while no drive is running. Says what to *do* when there is
    /// something to do — « Stopped » in front of a locked phone is true and useless.
    static func stoppedStatusKey(readiness: RecordingReadiness, interruption: CaptureInterruption?) -> String {
        guard !readiness.isReady else { return "carplay.stopped" }
        if interruption == .notRunnableInBackground { return "carplay.blocked.locked" }
        if interruption != nil { return "carplay.blocked.paused" }
        return "carplay.blocked.no_camera"
    }

    static func camerasKey(status: CaptureStatus) -> String {
        switch status.mode {
        case .dual: return status.frontActive ? "carplay.cameras.both" : "carplay.cameras.road"
        case .rearOnly: return "carplay.cameras.road"
        case .unavailable: return "carplay.cameras.none"
        }
    }
}
