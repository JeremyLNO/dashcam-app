import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

/// A message the recording screen (and CarPlay) should show the driver.
struct RecordingAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    var isCritical: Bool = false
}

/// Drives a drive: starts and stops the writers, indexes what they produce, and reacts
/// to everything that can go wrong while a car is moving.
///
/// It is the only place that knows a recording exists. `CaptureManager` knows about
/// cameras, `SegmentWriter` knows about files; neither knows what a session is.
@MainActor
final class RecordingManager: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var segmentCount: Int = 0
    @Published var alert: RecordingAlert?
    /// Set briefly after a Protect action so the UI (and CarPlay) can acknowledge it.
    @Published private(set) var lastProtectionConfirmation: Date?

    private let capture: CaptureManager
    private let settingsStore: SettingsStore
    private let index: SessionIndex
    private let protection: EventProtectionManager
    private let storage: StorageManager
    private let retention: RetentionManager
    private let location: LocationManager
    private let motion: MotionManager
    private let thermal: ThermalManager
    private let registry: ActiveFileRegistry

    private let engine = RecordingEngine()
    private var ticker: AnyCancellable?
    private var periodicSweep: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(
        capture: CaptureManager,
        settingsStore: SettingsStore,
        index: SessionIndex,
        protection: EventProtectionManager,
        storage: StorageManager,
        retention: RetentionManager,
        location: LocationManager,
        motion: MotionManager,
        thermal: ThermalManager,
        registry: ActiveFileRegistry
    ) {
        self.capture = capture
        self.settingsStore = settingsStore
        self.index = index
        self.protection = protection
        self.storage = storage
        self.retention = retention
        self.location = location
        self.motion = motion
        self.thermal = thermal
        self.registry = registry

        capture.sampleSink = engine
        wireEngine()
        wireSensors()
        wireThermal()
    }

    // MARK: - Public control

    func start() async {
        guard !isRecording else { return }

        // Refuse to start rather than begin a drive that will die two minutes in.
        let snapshot = storage.refresh()
        if snapshot.isCriticallyLow {
            let result = retention.sweep(settings: settingsStore.settings, reason: .lowSpace)
            if result.stillCritical {
                alert = RecordingAlert(titleKey: "alert.storage_full.title", messageKey: "alert.storage_full.message", isCritical: true)
                return
            }
        }

        guard capture.status.mode != .unavailable else {
            alert = RecordingAlert(
                titleKey: "alert.camera_unavailable.title",
                messageKey: capture.status.unavailability?.messageKey ?? "capture.error.no_camera",
                isCritical: true
            )
            return
        }

        thermal.begin(userQuality: settingsStore.settings.quality)

        let sessionID = UUID()
        let quality = thermal.effectiveQuality
        index.beginSession(id: sessionID, quality: quality)
        registry.reserveSessionPrefix(sessionID)

        let includesFront = capture.status.isDual && settingsStore.settings.frontCameraEnabled && !thermal.isFrontCameraShed
        engine.start(RecordingEngine.Configuration(
            sessionID: sessionID,
            rearFormat: capture.rearFormat,
            frontFormat: capture.frontFormat,
            includesFront: includesFront,
            includesAudio: capture.status.audioActive,
            segmentDuration: settingsStore.settings.segmentDuration.seconds
        ))

        currentSessionID = sessionID
        startedAt = Date()
        elapsed = 0
        segmentCount = 0
        isRecording = true

        startSensors()
        startTicker()
        // A dashcam whose screen locks mid-drive stops recording — iOS suspends the app.
        UIApplication.shared.isIdleTimerDisabled = true

        Log.recording.info("Recording started, session \(sessionID, privacy: .public), front=\(includesFront)")
    }

    func stop() async {
        guard isRecording, let sessionID = currentSessionID else { return }
        isRecording = false
        ticker?.cancel()
        ticker = nil
        UIApplication.shared.isIdleTimerDisabled = false
        stopSensors()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.stop { continuation.resume() }
        }

        index.endSession(id: sessionID)
        registry.releaseSessionPrefix(sessionID)
        currentSessionID = nil
        startedAt = nil

        retention.sweep(settings: settingsStore.settings, reason: .recordingFinished)
        storage.refresh()
        Log.recording.info("Recording stopped, session \(sessionID, privacy: .public)")
    }

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    /// The Protect button. Pins the five minutes behind and the two minutes ahead.
    @discardableResult
    func protectNow(origin: ProtectionOrigin = .manual, magnitude: Double = 0) -> Bool {
        guard let sessionID = currentSessionID else {
            alert = RecordingAlert(titleKey: "alert.protect_idle.title", messageKey: "alert.protect_idle.message")
            return false
        }
        protection.protect(sessionID: sessionID, origin: origin, magnitude: magnitude)
        lastProtectionConfirmation = Date()
        return true
    }

    // MARK: - Wiring

    private func wireEngine() {
        engine.onSegmentFinished = { [weak self] finished, sessionID in
            Task { @MainActor [weak self] in
                self?.indexSegment(finished, sessionID: sessionID)
            }
        }
        engine.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                Log.recording.error("Writer failure: \(error.localizedDescription, privacy: .public)")
                self?.alert = RecordingAlert(titleKey: "alert.write_failed.title", messageKey: "alert.write_failed.message", isCritical: true)
                await self?.stop()
            }
        }
    }

    private func indexSegment(_ finished: FinishedSegment, sessionID: UUID) {
        guard finished.succeeded else { return }

        // A segment landing inside a still-open protection window is born protected.
        let isProtected = protection.shouldProtectSegment(
            sessionID: sessionID, start: finished.startDate, end: finished.endDate
        )
        index.insertSegment(finished, sessionID: sessionID, isProtected: isProtected)
        segmentCount += 1

        // Every finalized segment is a good moment to check we are not about to run out.
        let snapshot = storage.refresh()
        guard snapshot.isCriticallyLow || exceedsLimit(snapshot) else { return }

        let result = retention.sweep(settings: settingsStore.settings, reason: .lowSpace)
        if result.stillCritical {
            alert = RecordingAlert(titleKey: "alert.storage_full.title", messageKey: "alert.storage_full.stopping", isCritical: true)
            Task { await stop() }
        }
    }

    private func exceedsLimit(_ snapshot: StorageSnapshot) -> Bool {
        guard let cap = settingsStore.settings.storageLimit.byteLimit else { return false }
        return snapshot.dashcamBytes > cap
    }

    private func wireSensors() {
        location.onSample = { [weak self] fix in
            guard let self, let sessionID = self.currentSessionID else { return }
            self.index.appendLocationSample(
                sessionID: sessionID,
                timestamp: fix.timestamp,
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                speed: fix.speed,
                course: fix.course,
                altitude: fix.altitude,
                accuracy: fix.horizontalAccuracy
            )
        }

        motion.onImpact = { [weak self] event in
            guard let self, self.isRecording else { return }
            self.protectNow(origin: .impact, magnitude: event.magnitude)
            self.alert = RecordingAlert(titleKey: "alert.impact.title", messageKey: "alert.impact.message")
        }
    }

    private func wireThermal() {
        thermal.onActionChanged = { [weak self] action in
            guard let self else { return }
            switch action {
            case .none:
                break
            case .reduceQuality:
                self.capture.applyDegradedQuality(self.thermal.effectiveQuality)
            case .dropFrontCamera:
                self.engine.dropFrontCamera()
            case .stopRecording:
                Task { await self.stop() }
            }
            if let key = action.messageKey {
                self.alert = RecordingAlert(titleKey: "alert.thermal.title", messageKey: key, isCritical: action == .stopRecording)
            }
        }

        capture.$status
            .sink { [weak self] status in
                self?.thermal.update(hardwareCost: status.hardwareCost, systemPressureCost: status.systemPressureCost)
                // A capture interruption while recording must not leave half-written
                // files behind; close the session cleanly and tell the driver.
                if let interruption = status.interruption, self?.isRecording == true {
                    self?.alert = RecordingAlert(
                        titleKey: "alert.interrupted.title",
                        messageKey: interruption.messageKey,
                        isCritical: true
                    )
                    Task { await self?.stop() }
                }
            }
            .store(in: &cancellables)
    }

    private func startSensors() {
        if settingsStore.settings.locationMetadataEnabled {
            location.start()
        }
        if settingsStore.settings.impactDetectionEnabled {
            motion.start(sensitivity: settingsStore.settings.shockSensitivity)
        }
    }

    private func stopSensors() {
        location.stop()
        motion.stop()
        index.save()
    }

    private func startTicker() {
        ticker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
    }

    /// Periodic housekeeping while the app is in the foreground and idle.
    func startPeriodicMaintenance() {
        periodicSweep = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.retention.sweep(settings: self.settingsStore.settings, reason: .periodic)
            }
    }

    func stopPeriodicMaintenance() {
        periodicSweep?.cancel()
        periodicSweep = nil
    }
}
