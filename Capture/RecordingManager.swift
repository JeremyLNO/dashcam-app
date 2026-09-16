import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

/// Something the sensors decided, with enough of it to react to.
struct DetectedEvent: Equatable, Sendable {
    let origin: ProtectionOrigin
    let magnitude: Double
    let at: Date
}

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

    /// The last event the *car* produced, as opposed to the driver.
    ///
    /// Published separately from `lastProtectionConfirmation`, which a manual Protect
    /// also sets: a driver who presses Protect from the discreet screen wants to stay
    /// discreet, and a collision is precisely the moment that decision stops holding.
    @Published private(set) var lastDetectedEvent: DetectedEvent?

    /// Called once a drive is closed and its index entry is final. The recorder does not
    /// care who listens — it exists so the automatic export can run on a finished drive
    /// rather than on one still being written to.
    var onSessionFinished: ((UUID) -> Void)?

    /// True while a drive is waiting for an interruption to clear.
    ///
    /// A phone call stops the capture — iOS gives the camera to the caller and there is
    /// nothing an app can do about it. What the app *can* do is remember that the driver
    /// never asked to stop, and start filming again the moment the hardware comes back.
    /// Without this, a two-minute call ended the drive for good: the app looked normal,
    /// the road was no longer being recorded, and the only sign was an alert already
    /// dismissed.
    @Published private(set) var isWaitingToResume = false

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
    private var distance = DistanceAccumulator()
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

        // Not « is there a camera » but « are pictures coming ». The two came apart on a
        // drive started from the car's screen with the iPhone locked: a camera existed, the
        // session existed, and iOS was delivering nothing to either. Cf. `RecordingReadiness`.
        if case .blocked(let titleKey, let messageKey) = RecordingReadiness.assess(capture.status) {
            alert = RecordingAlert(titleKey: titleKey, messageKey: messageKey, isCritical: true)
            Log.recording.error("Refused to start: \(messageKey, privacy: .public)")
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
        distance.reset()
        startedAt = Date()
        elapsed = 0
        segmentCount = 0
        isRecording = true

        startSensors()
        startTicker()
        // A dashcam whose screen locks mid-drive stops recording — iOS suspends the app.
        UIApplication.shared.isIdleTimerDisabled = true

        Log.recording.info("Recording started, session \(sessionID, privacy: .public), front=\(includesFront)")
        watchForFirstFrame(of: sessionID, startedAt: startedAt ?? Date())
    }

    /// The second belt, and the one that does not take iOS at its word.
    ///
    /// Everything above can pass — a camera present, a session running, no interruption
    /// posted — and still not one frame arrive. That is precisely what happened from
    /// CarPlay, and nothing in the app noticed: the timer ticked, the template said
    /// RECORDING, the writers waited for a first sample that never came, and the drive
    /// ended with no files and a session row nobody could explain.
    ///
    /// So the drive is asked to show its work. No frame within the grace period and it is
    /// stopped and said out loud, rather than left running for an hour over nothing.
    private func watchForFirstFrame(of sessionID: UUID, startedAt: Date) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RecordingReadiness.firstFrameGrace * 1_000_000_000))
            guard let self, self.isRecording, self.currentSessionID == sessionID else { return }
            guard !RecordingReadiness.hasReceivedFootage(
                startedAt: startedAt, lastFrame: self.capture.lastVideoFrame
            ) else { return }

            Log.recording.error("No frame after \(RecordingReadiness.firstFrameGrace, privacy: .public)s — stopping a drive that is recording nothing")
            await self.stop()
            self.alert = RecordingAlert(
                titleKey: "alert.camera_unavailable.title",
                messageKey: "capture.interrupted.background",
                isCritical: true
            )
        }
    }

    func stop() async {
        await stop(keepingResumeIntent: false)
    }

    /// `keepingResumeIntent` is the difference between "the driver pressed Stop" and
    /// "iOS took the camera away": only the second one may start again on its own.
    func stop(keepingResumeIntent: Bool) async {
        if !keepingResumeIntent { isWaitingToResume = false }
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
        onSessionFinished?(sessionID)
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
        let segment = index.insertSegment(finished, sessionID: sessionID, isProtected: isProtected)
        segmentCount += 1
        if let segment { hashInBackground(segment) }

        // Every finalized segment is a good moment to check we are not about to run out.
        let snapshot = storage.refresh()
        guard snapshot.isCriticallyLow || exceedsLimit(snapshot) else { return }

        let result = retention.sweep(settings: settingsStore.settings, reason: .lowSpace)
        if result.stillCritical {
            alert = RecordingAlert(titleKey: "alert.storage_full.title", messageKey: "alert.storage_full.stopping", isCritical: true)
            Task { await stop() }
        }
    }

    /// Computes the segment's SHA-256 away from the main actor and stores it.
    ///
    /// This is what makes an exported proof bundle verifiable later, and it runs at
    /// utility priority precisely because it must never compete with the two camera
    /// streams that are still writing.
    private func hashInBackground(_ segment: VideoSegment) {
        let id = segment.id
        let url = StorageLocations.absoluteURL(forRelativePath: segment.relativePath)
        // The index, not self, is what the completion needs; capturing it directly keeps
        // the detached task free of any reference back to a main-actor object.
        let index = self.index
        Task.detached(priority: .utility) {
            guard let digest = FileDigest.sha256(of: url) else { return }
            await MainActor.run { index.setDigest(digest, forSegmentID: id) }
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
            self.accumulateDistance(to: fix, sessionID: sessionID)
            // The same fix, written inside the files as well as beside them: a video
            // handed to someone else carries its own positions.
            self.engine.appendMetadata(location: fix, gForce: nil)
        }

        motion.onImpact = { [weak self] event in
            guard let self, self.isRecording else { return }
            self.protectNow(origin: .impact, magnitude: event.magnitude)
            self.lastDetectedEvent = DetectedEvent(origin: .impact, magnitude: event.magnitude, at: Date())
            self.alert = RecordingAlert(titleKey: "alert.impact.title", messageKey: "alert.impact.message")
        }

        motion.onHarshBraking = { [weak self] event in
            guard let self, self.isRecording else { return }
            self.protectNow(origin: .harshBraking, magnitude: event.magnitude)
            self.lastDetectedEvent = DetectedEvent(origin: .harshBraking, magnitude: event.magnitude, at: Date())
            self.alert = RecordingAlert(titleKey: "alert.braking.title", messageKey: "alert.braking.message")
        }

        motion.onSecondElapsed = { [weak self] date, peak in
            guard let self, let sessionID = self.currentSessionID else { return }
            self.index.appendMotionSample(sessionID: sessionID, timestamp: date, peakG: peak)
            self.engine.appendMetadata(location: nil, gForce: peak)
        }
    }

    private func accumulateDistance(to fix: CLLocation, sessionID: UUID) {
        let metres = distance.add(fix)
        guard metres > 0 else { return }
        index.updateStatistics(sessionID: sessionID, addingMetres: metres)
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
                //
                // ⚠️ Unless it only took the microphone. That fires whenever any other app
                // wants the mic — Siri, a voice memo, a navigation app speaking a turn —
                // and the cameras keep running throughout. Ending the drive there, with a
                // modal on top, made a phone that speaks directions unable to film: the
                // road was lost to protect the sound, which is the wrong way round for a
                // dashcam. The drive carries on without sound and says so once.
                if let interruption = status.interruption, self?.isRecording == true {
                    guard interruption.affectsVideo else {
                        self?.engine.setAudioAvailable(false)
                        Log.recording.info("Microphone taken by another app — the drive continues without sound")
                        return
                    }
                    self?.alert = RecordingAlert(
                        titleKey: "alert.interrupted.title",
                        messageKey: interruption.messageKey,
                        isCritical: true
                    )
                    self?.isWaitingToResume = interruption.isTemporary
                    Task { await self?.stop(keepingResumeIntent: interruption.isTemporary) }
                }

                // The microphone came back. Later segments carry sound again; the ones
                // written meanwhile simply have none, which is honest.
                if status.interruption == nil, self?.isRecording == true {
                    self?.engine.setAudioAvailable(status.audioActive)
                }

                // The hardware is back. A drive that was interrupted rather than stopped
                // starts again by itself — a new drive in the library, because the
                // footage really is discontinuous, but no gap the driver has to notice.
                if status.interruption == nil, self?.isWaitingToResume == true, status.isRunning {
                    self?.isWaitingToResume = false
                    Task { [weak self] in
                        guard let self, !self.isRecording else { return }
                        Log.recording.info("Resuming after an interruption")
                        await self.start()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Switches on everything that records *beside* the video: position and motion.
    ///
    /// ⚠️ **Every origin passes through here**, and that is the guarantee, not a detail: the
    /// button on the driving screen, the CarPlay template, the Apple Watch, a Shortcut, the
    /// automatic start when the car connects, the resume after an interruption — all of them
    /// call `start()`, so none of them can produce a drive without its positions. Anything
    /// that ever reaches the capture engine by another road would record a journey with no
    /// coordinates, and nothing on screen would say so. See `CarPlayLocationTests`.
    private func startSensors() {
        if settingsStore.settings.locationMetadataEnabled {
            // The setting is on by default, but nothing had ever triggered the system
            // prompt: it only fired when the user toggled the switch. A fresh install
            // could therefore never get a fix, and the GPS tile stayed Off forever.
            // Starting a recording is exactly the moment the permission makes sense.
            if location.authorization == .notDetermined {
                location.requestAuthorization()
            }
            location.start()
        }
        if settingsStore.settings.impactDetectionEnabled {
            motion.start(
                sensitivity: settingsStore.settings.shockSensitivity,
                detectsHarshBraking: settingsStore.settings.harshBrakingDetectionEnabled
            )
        }
    }

    /// The mirror, and the same rule: whoever ends the drive — CarPlay included — releases
    /// the receiver. The save is what makes the fixes gathered since the last segment
    /// survive the end of the session; a position inserted and never written is
    /// indistinguishable from a position that was recorded, until the next launch.
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
