import Combine
import Foundation
import SwiftData
import SwiftUI

/// The object graph, assembled once.
///
/// Everything is constructed here and handed to whoever needs it — there is no service
/// locator and no manager reaching out for a global. The one static, `shared`, exists for
/// exactly one reason: UIKit instantiates `CarPlaySceneDelegate` itself and gives it no
/// way to receive an injected dependency.
@MainActor
final class AppEnvironment: ObservableObject {
    /// Set by `AppDelegate` at launch, read only by the CarPlay scene delegate.
    static var shared: AppEnvironment?

    let configuration: AppConfiguration
    let container: ModelContainer

    let language: LanguageManager
    let settingsStore: SettingsStore
    let index: SessionIndex
    let registry: ActiveFileRegistry
    let storage: StorageManager
    let retention: RetentionManager
    let recovery: RecoveryManager
    let protection: EventProtectionManager
    let location: LocationManager
    let motion: MotionManager
    let thermal: ThermalManager
    let capture: CaptureManager
    let recording: RecordingManager
    let subscriptions: SubscriptionManager
    let exporter: ExportManager
    let autoExporter: AutoExporter
    let permissions: PermissionCoordinator
    let notifications: NotificationManager
    let review: ReviewPrompter
    /// Owned here rather than by the driving screen, since the CarPlay remote turns it on
    /// and off too — and since the end of a drive has to end it whatever the phone happens
    /// to be showing at that moment.
    let dimmer = ScreenDimmer()

    let carPlay: CarPlayManager
    let watchRemote: PhoneRemoteServer
    let carPlayConnection: CarPlayConnectionMonitor

    private var cancellables = Set<AnyCancellable>()

    init(inMemory: Bool = false) {
        let configuration = AppConfiguration.load()
        self.configuration = configuration
        self.container = PersistenceController.makeContainer(inMemory: inMemory)

        self.language = LanguageManager.shared
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore

        let index = SessionIndex(container: container)
        self.index = index

        let registry = ActiveFileRegistry()
        self.registry = registry

        let storage = StorageManager(index: index)
        self.storage = storage
        self.retention = RetentionManager(index: index, storage: storage, registry: registry)
        self.recovery = RecoveryManager(index: index)
        self.protection = EventProtectionManager(index: index)
        self.location = LocationManager()
        self.motion = MotionManager()
        self.thermal = ThermalManager()

        let capture = CaptureManager()
        self.capture = capture

        let subscriptions = SubscriptionManager(configuration: configuration)
        self.subscriptions = subscriptions
        let exporter = ExportManager(index: index, subscriptions: subscriptions, registry: registry)
        self.exporter = exporter
        let autoExporter = AutoExporter(
            index: index, exporter: exporter, settingsStore: settingsStore, subscriptions: subscriptions
        )
        self.autoExporter = autoExporter
        let permissions = PermissionCoordinator()
        self.permissions = permissions
        self.notifications = NotificationManager(configuration: configuration)
        self.review = ReviewPrompter(installDate: settingsStore.installDate, configuration: configuration)

        let recording = RecordingManager(
            capture: capture,
            settingsStore: settingsStore,
            index: index,
            protection: self.protection,
            storage: storage,
            retention: self.retention,
            location: self.location,
            motion: self.motion,
            thermal: self.thermal,
            registry: registry
        )
        self.recording = recording
        // A finished drive is the only moment the protected windows are complete: their
        // forward half is footage that did not exist when the event fired.
        // The end of a drive is also the one moment every figure on the widget changes at
        // once. Captured piece by piece rather than through `self`, which is not fully
        // formed at this point in the initialiser.
        recording.onSessionFinished = { [weak autoExporter, index, storage, settingsStore] sessionID in
            Task { await autoExporter?.exportProtectedFootage(ofSession: sessionID) }
            Task { @MainActor in
                WidgetFeeder(index: index, storage: storage, settingsStore: settingsStore).refresh()
            }
        }
        // Control Center's buttons are performed by the app once it has been opened, so
        // this is where they find something to act on.
        ControlBridge.startRecording = { [weak recording] in
            guard let recording, !recording.isRecording else { return }
            await recording.start()
        }
        ControlBridge.stopRecording = { [weak recording] in await recording?.stop() }
        ControlBridge.protectFootage = { [weak recording] in
            recording?.protectNow(origin: .manual)
        }

        self.carPlay = CarPlayManager(
            recording: recording, capture: capture, storage: storage, dimmer: dimmer
        )
        self.watchRemote = PhoneRemoteServer(recording: recording, index: index)
        self.carPlayConnection = CarPlayConnectionMonitor()

        // The export renderer needs the overlay preferences but has no business owning
        // the settings object; this is the one wire between them.
        SettingsSnapshotProvider.current = { [weak settingsStore] in
            settingsStore?.settings ?? RecordingSettings()
        }

        let locationManager = self.location
        permissions.locationStatusProvider = { locationManager.authorization }
        permissions.refresh()

        observeSettings()
        observeCarPlay()
        observeRecordingForDiscreetScreen()
    }

    /// Acts on what the driver asked for about location, whatever iOS currently allows.
    ///
    /// Called when the app comes to the front and when it leaves. The case that makes it
    /// necessary: **Allow Once**. iOS returns the authorisation to *not determined* at the
    /// next launch, so a driver who granted location yesterday finds it off today — and
    /// the app used to accept that silently rather than ask again.
    /// Raises the *Always* prompt, once, and remembers that it was raised.
    ///
    /// iOS shows it a single time per install and says nothing on the second call. Without
    /// this memory the settings row would stay there offering a prompt that no longer
    /// appears — a control that does nothing is worse than no control, and at the wheel it
    /// is worse still.
    func requestAlwaysLocation() {
        guard LocationUpgrade.decide(
            authorization: location.authorization,
            wantsLocation: settingsStore.settings.locationMetadataEnabled,
            hasAlreadyAsked: hasAskedForAlwaysLocation
        ) == .ask else { return }
        hasAskedForAlwaysLocation = true
        location.requestAlwaysAuthorization()
    }

    /// Persisted rather than held in memory: the prompt's one shot is spent for the life of
    /// the install, not for the life of the process.
    private(set) var hasAskedForAlwaysLocation: Bool {
        get { UserDefaults.standard.bool(forKey: "location.askedAlways") }
        set { UserDefaults.standard.set(newValue, forKey: "location.askedAlways") }
    }

    func applyLocationIntent(isForeground: Bool) {
        let intent = LocationIntent.decide(
            wantsLocation: settingsStore.settings.locationMetadataEnabled,
            authorization: location.authorization,
            isRecording: recording.isRecording,
            isUpdating: location.isUpdating,
            isForeground: isForeground
        )
        switch intent {
        case .request: location.requestAuthorization()
        case .start: location.start()
        case .stop: location.stop()
        case .none: break
        }
    }

    /// Rebuilds the widget's snapshot and asks iOS to redraw it.
    ///
    /// Called on events rather than on a schedule: a widget refreshed on a timer shows
    /// whatever was true when the timer last fired, and looks exactly like one that is up
    /// to date.
    func refreshWidgets() {
        WidgetFeeder(index: index, storage: storage, settingsStore: settingsStore).refresh()
    }

    /// The end of a drive gives the brightness back.
    ///
    /// Wired here, not in the driving screen: a drive can be stopped from the car, from the
    /// Watch or by running out of storage while the phone shows the library, and in none of
    /// those cases is the driving screen there to notice. A phone left at 5 % is a defect
    /// the app does not even see.
    private func observeRecordingForDiscreetScreen() {
        recording.$isRecording
            .sink { [weak self] isRecording in
                guard !isRecording else { return }
                Task { @MainActor in self?.dimmer.exit() }
            }
            .store(in: &cancellables)
    }

    /// A drive can begin from CarPlay, the Watch or a Shortcut while the phone shows the
    /// library — where the cameras have been stopped on purpose. They have to come back, or
    /// the drive records nothing, which is the very defect this session set out to end.
    func ensureCamerasRunningForRecording() {
        guard recording.isRecording else { return }
        capture.startRunning()
    }

    /// Starts a recording when the car is plugged in, if the driver asked for that.
    private func observeCarPlay() {
        carPlay.shouldAutoStartOnConnect = { [weak self] in
            guard let self else { return false }
            return CarPlayConnectionMonitor.shouldAutoStart(
                isEnabled: self.settingsStore.settings.startOnCarPlayConnect,
                isAlreadyRecording: self.recording.isRecording,
                isCameraReady: self.capture.status.mode != .unavailable
            )
        }

        carPlayConnection.onConnected = { [weak self] in
            guard let self else { return }
            guard CarPlayConnectionMonitor.shouldAutoStart(
                isEnabled: self.settingsStore.settings.startOnCarPlayConnect,
                isAlreadyRecording: self.recording.isRecording,
                isCameraReady: self.capture.status.mode != .unavailable
            ) else { return }
            Task { await self.recording.start() }
        }
    }

    /// Launch work that can touch disk or the network. Called once from `AppDelegate`.
    func bootstrap() async {
        subscriptions.bootstrap()
        notifications.bootstrap()
        storage.refresh()

        await recovery.recover()
        retention.sweep(settings: settingsStore.settings, reason: .launch)
        recording.startPeriodicMaintenance()

        await capture.configureAndStart(settings: settingsStore.settings)

        if settingsStore.settings.autoStartOnLaunch,
           settingsStore.hasCompletedOnboarding,
           capture.status.mode != .unavailable {
            await recording.start()
        }

        refreshWidgets()
        await notifications.checkForUpdate()
    }

    /// Reacts to the settings that need the pipeline rebuilt or a sweep re-run.
    private func observeSettings() {
        settingsStore.$settings
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] settings in
                guard let self else { return }
                Task { @MainActor in
                    self.motion.updateSensitivity(settings.shockSensitivity)
                    if settings.recordAudio != self.capture.status.audioActive {
                        self.capture.setAudioEnabled(settings.recordAudio)
                    }
                    self.retention.sweep(settings: settings, reason: .settingsChanged)
                }
            }
            .store(in: &cancellables)
    }

    /// Rebuilds the capture graph. Needed when the quality tier or the cabin-camera
    /// switch changes, because a live multi-cam session cannot be re-shaped in place.
    func reconfigureCapture() async {
        let wasRecording = recording.isRecording
        if wasRecording { await recording.stop() }
        await capture.configureAndStart(settings: settingsStore.settings)
        if wasRecording { await recording.start() }
    }
}
