#if canImport(CarPlay)
import CarPlay
#endif
import Combine
import Foundation

/// The CarPlay screen, which is a remote control and nothing else.
///
/// There is no navigation here, and there never will be: the driver keeps using Maps,
/// Waze or Google Maps, and Dashcam offers three buttons — Start, Stop, Protect. Every
/// setting stays on the phone, where it can be changed while parked.
///
/// The whole feature is optional. Without the `carplay-driving-task` entitlement the
/// template scene is simply never created by iOS, and nothing in the phone app notices.
@MainActor
final class CarPlayManager: ObservableObject {
    @Published private(set) var isConnected = false

    private let recording: RecordingManager
    /// Asked when the CarPlay screen connects, so the same preference governs both paths.
    var shouldAutoStartOnConnect: () -> Bool = { false }
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    #if canImport(CarPlay)
    private var interfaceController: CPInterfaceController?
    private var template: CPInformationTemplate?
    #endif

    init(recording: RecordingManager) {
        self.recording = recording
    }

    // MARK: - Scene lifecycle

    #if canImport(CarPlay)
    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        isConnected = true

        let template = makeTemplate()
        self.template = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        observeRecording()
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
        let template = CPInformationTemplate(
            title: L10n.t("carplay.title"),
            layout: .leading,
            items: currentItems(),
            actions: currentActions()
        )
        return template
    }

    private func currentItems() -> [CPInformationItem] {
        if recording.isRecording {
            var items = [
                CPInformationItem(title: L10n.t("carplay.status"), detail: L10n.t("carplay.recording")),
                CPInformationItem(title: L10n.t("carplay.duration"), detail: Format.duration(recording.elapsed)),
            ]
            if let confirmation = recording.lastProtectionConfirmation,
               Date().timeIntervalSince(confirmation) < 6 {
                items.append(CPInformationItem(title: L10n.t("carplay.protected"), detail: L10n.t("carplay.protected.detail")))
            }
            return items
        }
        return [CPInformationItem(title: L10n.t("carplay.status"), detail: L10n.t("carplay.stopped"))]
    }

    private func currentActions() -> [CPTextButton] {
        if recording.isRecording {
            return [
                CPTextButton(title: L10n.t("carplay.stop"), textStyle: .cancel) { [weak self] _ in
                    Task { @MainActor in await self?.recording.stop() }
                },
                CPTextButton(title: L10n.t("carplay.protect"), textStyle: .confirm) { [weak self] _ in
                    Task { @MainActor in self?.protectFromCarPlay() }
                },
            ]
        }
        return [
            CPTextButton(title: L10n.t("carplay.start"), textStyle: .confirm) { [weak self] _ in
                Task { @MainActor in await self?.recording.start() }
            }
        ]
    }

    private func protectFromCarPlay() {
        recording.protectNow(origin: .carPlay)
        refresh()
    }

    private func observeRecording() {
        recording.$isRecording
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        // The duration line has to tick, but only while there is something to tick.
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
