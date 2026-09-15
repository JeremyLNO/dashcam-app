#if canImport(CarPlay)
import CarPlay
import UIKit
#endif
import Combine
import Foundation

/// The CarPlay screen: one question, answered in under a second — **what can I do now?**
///
/// Three screens, never more. No settings, no library, no camera preview: a driving-task
/// app on CarPlay is a remote control, and everything it offers is something a driver can
/// press without reading. START and STOP are never on screen together.
///
/// ⚠️ **CarPlay does not allow a custom-drawn interface here.** Only navigation apps get a
/// surface to draw on; a `carplay-driving-task` app composes system templates, whose
/// layout, type sizes and spacing belong to the car. So the hierarchy asked for is built
/// out of the largest thing available — `CPGridTemplate`, whose buttons are big tiles —
/// with the secondary facts pushed into the title bar where they cannot compete.
///
/// And because none of it can be tried on this machine, every root template is set with a
/// completion handler: if the car refuses a grid, the information template takes over
/// rather than leaving the driver a blank screen.
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

    /// Shown for a moment instead of the title, then gone on its own.
    private var confirmation: CarPlayConfirmation?
    private var confirmationTimer: Timer?

    #if canImport(CarPlay)
    private var interfaceController: CPInterfaceController?
    private var currentScreen: CarPlayScreen?
    private var gridTemplate: CPGridTemplate?
    private var informationTemplate: CPInformationTemplate?
    /// Set once the car has refused a grid. Nothing tries again afterwards: a second
    /// refusal per state change would be a flicker between two layouts.
    private var gridIsUnavailable = false
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
        currentScreen = nil
        observeState()
        present(screen())
        Log.carplay.info("CarPlay connected")

        if shouldAutoStartOnConnect(), !recording.isRecording {
            Task { @MainActor in await recording.start() }
        }
    }

    func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmation = nil
        cancellables.removeAll()
        interfaceController = nil
        gridTemplate = nil
        informationTemplate = nil
        currentScreen = nil
        isConnected = false
        Log.carplay.info("CarPlay disconnected")
    }

    // MARK: - Which screen

    private func screen() -> CarPlayScreen {
        CarPlayScreen.decide(
            isRecording: recording.isRecording,
            readiness: RecordingReadiness.assess(capture.status),
            camerasKey: CarPlayDashboard.camerasKey(status: capture.status),
            isDiscreet: dimmer.isDiscreet
        )
    }

    /// The title bar carries everything that is not the action: the state, the elapsed
    /// time, and — only when there is room to spare — the two facts worth a glance.
    private func title(for screen: CarPlayScreen) -> String {
        if let confirmation { return L10n.t(confirmation.titleKey) }
        switch screen {
        case .blocked:
            return L10n.t("carplay.blocked.title")
        case .ready(let camerasKey):
            return "\(L10n.t("carplay.ready")) · \(L10n.t(camerasKey)) · \(Format.bytes(storage.snapshot.freeBytes))"
        case .recording:
            return "\(L10n.t("carplay.recording"))  \(Format.duration(recording.elapsed))"
        }
    }

    // MARK: - Presenting

    /// Swaps the root template when the screen *changes*, and only then. Re-rooting on
    /// every tick would reset the car's own animations once a second.
    private func present(_ screen: CarPlayScreen) {
        guard let interfaceController else { return }
        let isSameShape = currentScreen.map { Self.sameShape($0, screen) } ?? false
        if isSameShape {
            refreshInPlace(screen)
            return
        }
        currentScreen = screen

        if screen.actions.isEmpty || gridIsUnavailable {
            let template = makeInformationTemplate(screen)
            informationTemplate = template
            gridTemplate = nil
            interfaceController.setRootTemplate(template, animated: false, completion: nil)
            return
        }

        let grid = makeGridTemplate(screen)
        interfaceController.setRootTemplate(grid, animated: false) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                guard success else {
                    // The car would not take a grid. Fall back once, for good, rather than
                    // leave the driver looking at nothing.
                    Log.carplay.error("Grid refused: \(error?.localizedDescription ?? "no reason", privacy: .public) — falling back")
                    self.gridIsUnavailable = true
                    self.currentScreen = nil
                    self.present(self.screen())
                    return
                }
                self.gridTemplate = grid
                self.informationTemplate = nil
            }
        }
    }

    /// Two screens have the same *shape* when they need the same buttons — only then can
    /// the title and the tiles be updated without re-rooting.
    private static func sameShape(_ lhs: CarPlayScreen, _ rhs: CarPlayScreen) -> Bool {
        lhs.actions == rhs.actions
    }

    private func refreshInPlace(_ screen: CarPlayScreen) {
        currentScreen = screen
        if let gridTemplate {
            gridTemplate.updateTitle(title(for: screen))
            gridTemplate.updateGridButtons(buttons(for: screen))
        }
        if let informationTemplate {
            informationTemplate.title = title(for: screen)
            informationTemplate.items = informationItems(screen)
            informationTemplate.actions = textButtons(for: screen)
        }
    }

    // MARK: - Templates

    private func makeGridTemplate(_ screen: CarPlayScreen) -> CPGridTemplate {
        CPGridTemplate(title: title(for: screen), gridButtons: buttons(for: screen))
    }

    /// The fallback, and the only shape available for the blocked screen — a grid needs at
    /// least one button, and the blocked screen deliberately has none.
    private func makeInformationTemplate(_ screen: CarPlayScreen) -> CPInformationTemplate {
        CPInformationTemplate(
            title: title(for: screen),
            layout: .leading,
            items: informationItems(screen),
            actions: textButtons(for: screen)
        )
    }

    private func informationItems(_ screen: CarPlayScreen) -> [CPInformationItem] {
        switch screen {
        case .blocked(let detailKey):
            // One line, and nothing to compete with it. No storage, no camera list: the
            // driver has exactly one thing to do and the screen says only that.
            return [CPInformationItem(title: L10n.t("carplay.blocked.title"), detail: L10n.t(detailKey))]
        case .ready(let camerasKey):
            return [
                CPInformationItem(title: L10n.t("carplay.status"), detail: L10n.t("carplay.ready")),
                CPInformationItem(title: L10n.t("carplay.cameras"), detail: L10n.t(camerasKey)),
                CPInformationItem(title: L10n.t("carplay.storage"), detail: Format.bytes(storage.snapshot.freeBytes)),
            ]
        case .recording:
            return [
                CPInformationItem(title: L10n.t("carplay.status"), detail: L10n.t("carplay.recording")),
                CPInformationItem(title: L10n.t("carplay.duration"), detail: Format.duration(recording.elapsed)),
                CPInformationItem(title: L10n.t("carplay.clips"), detail: "\(recording.segmentCount)"),
            ]
        }
    }

    // MARK: - Buttons

    private func buttons(for screen: CarPlayScreen) -> [CPGridButton] {
        screen.actions.map { action in
            CPGridButton(titleVariants: [label(for: action)], image: image(for: action)) { [weak self] _ in
                Task { @MainActor in self?.perform(action) }
            }
        }
    }

    private func textButtons(for screen: CarPlayScreen) -> [CPTextButton] {
        screen.actions.map { action in
            CPTextButton(title: label(for: action), textStyle: style(for: action)) { [weak self] _ in
                Task { @MainActor in self?.perform(action) }
            }
        }
    }

    private func label(for action: CarPlayScreen.Action) -> String {
        switch action {
        case .start: return L10n.t("carplay.start")
        case .stop: return L10n.t("carplay.stop")
        case .protectClip:
            return L10n.t(confirmation == .clipProtected ? "carplay.protect.done" : "carplay.protect")
        case .discreet: return L10n.t(dimmer.isDiscreet ? "carplay.screen.wake" : "carplay.screen.dim")
        }
    }

    private func style(for action: CarPlayScreen.Action) -> CPTextButtonStyle {
        switch action {
        case .start: return .confirm
        case .stop: return .cancel
        case .protectClip, .discreet: return .normal
        }
    }

    /// Green to start, red to stop, and a shield that is neither — the three states a
    /// driver recognises without reading.
    ///
    /// ⚠️ Rendered `.alwaysOriginal`: CarPlay tints template images itself, and a red Stop
    /// that arrives as a grey Stop is the rule this screen is built on. If the car tints it
    /// anyway the icon simply loses its colour — the layout, and the size, are unaffected.
    private func image(for action: CarPlayScreen.Action) -> UIImage {
        switch action {
        case .start: return Self.symbol("record.circle.fill", tint: .systemGreen)
        case .stop: return Self.symbol("stop.circle.fill", tint: .systemRed)
        case .protectClip:
            return confirmation == .clipProtected
                ? Self.symbol("checkmark.shield.fill", tint: .systemGreen)
                : Self.symbol("shield.lefthalf.filled", tint: .systemBlue)
        case .discreet:
            return Self.symbol(dimmer.isDiscreet ? "sun.max.fill" : "moon.fill", tint: .systemYellow)
        }
    }

    /// CarPlay asks for a 60×60 pt image. Drawn once per call rather than cached: these are
    /// built on a state change, which happens a handful of times per drive.
    private static func symbol(_ name: String, tint: UIColor) -> UIImage {
        let size = CGSize(width: 60, height: 60)
        let configuration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { _ in
            guard let symbol else { return }
            let rect = CGRect(
                x: (size.width - symbol.size.width) / 2,
                y: (size.height - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            )
            symbol.draw(in: rect)
        }
    }

    // MARK: - Doing

    private func perform(_ action: CarPlayScreen.Action) {
        switch action {
        case .start:
            Task { @MainActor in await recording.start() }
        case .stop:
            Task { @MainActor in
                await recording.stop()
                // The confirmation belongs to the screen that follows, which is why it is
                // raised after the stop rather than with it.
                show(.driveSaved)
            }
        case .protectClip:
            guard recording.protectNow(origin: .carPlay) else { return }
            show(.clipProtected)
        case .discreet:
            if dimmer.isDiscreet {
                dimmer.exit()
            } else {
                dimmer.enter(whileRecording: recording.isRecording)
            }
            refresh()
        }
    }

    /// Says it, and leaves. Nothing to press: asking a driver to acknowledge « saved » is
    /// asking them to look at the screen to dismiss news they already wanted.
    private func show(_ confirmation: CarPlayConfirmation) {
        self.confirmation = confirmation
        refresh()
        confirmationTimer?.invalidate()
        confirmationTimer = Timer.scheduledTimer(withTimeInterval: CarPlayConfirmation.duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.confirmation = nil
                self?.refresh()
            }
        }
    }

    // MARK: - Keeping it current

    private func observeState() {
        // Three publishers, one refresh. The capture status is the one that was missing:
        // without it, a screen saying « open the app » stayed that way after it was opened.
        for publisher in [
            recording.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            capture.$status.map { _ in () }.eraseToAnyPublisher(),
            dimmer.$isDiscreet.map { _ in () }.eraseToAnyPublisher(),
        ] {
            publisher
                .sink { [weak self] in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
        }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording.isRecording else { return }
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard isConnected else { return }
        present(screen())
    }
    #else
    func disconnect() { isConnected = false }
    #endif
}

/// What the car's screen says, as plain decisions over the capture state.
///
/// Kept apart from the templates so it can be tested: `CPGridTemplate` cannot be built on a
/// machine without CarPlay, and these are exactly the lines that were wrong.
enum CarPlayDashboard {
    static func camerasKey(status: CaptureStatus) -> String {
        switch status.mode {
        case .dual: return status.frontActive ? "carplay.cameras.both" : "carplay.cameras.road"
        case .rearOnly: return "carplay.cameras.road"
        case .unavailable: return "carplay.cameras.none"
        }
    }
}
