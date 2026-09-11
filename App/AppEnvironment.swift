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
    let permissions: PermissionCoordinator
    let notifications: NotificationManager
    let review: ReviewPrompter
    let carPlay: CarPlayManager
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
        self.exporter = ExportManager(index: index, subscriptions: subscriptions, registry: registry)
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
        self.carPlay = CarPlayManager(recording: recording)
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
