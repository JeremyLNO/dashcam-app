import CoreMotion
import Foundation

/// A detected impact, with enough context to explain itself.
struct ImpactEvent: Equatable, Sendable {
    let date: Date
    /// Peak total acceleration, in g, excluding gravity.
    let magnitude: Double
}

/// A sustained heavy deceleration — an emergency stop rather than a collision.
struct HarshBrakingEvent: Equatable, Sendable {
    let date: Date
    /// Peak deceleration held through the event, in g.
    let magnitude: Double
    let duration: TimeInterval
}

/// Accelerometer-based crash detection.
///
/// The hard part is not detecting a spike — it is *not* firing on the dozens of spikes a
/// phone in a car produces every hour. Four filters run in series:
///
/// 1. **Amplitude.** Peak acceleration must exceed the sensitivity threshold.
/// 2. **Sharpness.** A real impact is a step, not a ramp. The jerk (change in
///    acceleration between two 50 Hz samples) must exceed a floor, which rejects normal
///    and even hard braking — those build up over hundreds of milliseconds.
/// 3. **Brevity.** The excursion must end quickly. A pothole or a speed bump is a short
///    sharp spike too, so this alone is not sufficient, which is why the next filter
///    exists.
/// 4. **Handling rejection.** If the gyroscope shows the device was being rotated
///    (picked up, re-cradled, knocked), the spike is discarded: a phone being handled
///    produces exactly the amplitude and sharpness of a minor collision.
///
/// Plus a cooldown, so one collision produces one event and not forty.
///
/// Harsh braking is detected by the *mirror* of those rules. Where a collision is a step
/// — large, sharp, over in a tenth of a second — an emergency stop is a ramp: it climbs
/// gently, sits above half a g for half a second or more, and fades. So the braking
/// detector requires duration and forbids sharpness, which is exactly what the impact
/// detector rejects. The two cannot fire on the same excursion.
@MainActor
final class MotionManager: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastImpact: ImpactEvent?
    /// Live magnitude, exposed for the Settings sensitivity screen so the user can see
    /// what their driving actually produces.
    @Published private(set) var currentMagnitude: Double = 0

    var onImpact: ((ImpactEvent) -> Void)?
    var onHarshBraking: ((HarshBrakingEvent) -> Void)?
    /// Peak acceleration for the second that just elapsed. Fires once a second while
    /// monitoring, so a drive carries a G-force history without storing 50 rows a second.
    var onSecondElapsed: ((Date, Double) -> Void)?

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var sensitivity: ShockSensitivity = .normal

    private let sampleRate: Double = 50
    private let cooldown: TimeInterval = 10
    /// Rotation, rad/s. Above this the device is being handled, not driven.
    private let handlingRotationThreshold: Double = 2.5
    /// g per sample at 50 Hz. Braking never gets close; an impact clears it easily.
    private let jerkThreshold: Double = 0.9
    /// An excursion longer than this is a manoeuvre, not a collision.
    private let maximumExcursion: TimeInterval = 0.35
    /// Past this, it is not a discrete event at all — a rough road, or shaking.
    private let maximumSustainedExcursion: TimeInterval = 2.5

    private var previousMagnitude: Double = 0
    private var excursionStart: Date?
    private var excursionPeak: Double = 0
    private var excursionSawSharpEdge = false
    private var excursionSawHandling = false
    private var lastEventDate: Date?
    private var lastBrakingDate: Date?
    private var detectsHarshBraking = true
    private var secondStart: Date?
    private var secondPeak: Double = 0

    init() {
        queue.name = "dashcam.lno.company.motion"
        queue.maxConcurrentOperationCount = 1
    }

    func start(sensitivity: ShockSensitivity, detectsHarshBraking: Bool = true) {
        self.sensitivity = sensitivity
        self.detectsHarshBraking = detectsHarshBraking
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else {
            isMonitoring = motion.isDeviceMotionActive
            return
        }
        motion.deviceMotionUpdateInterval = 1 / sampleRate
        secondStart = nil
        secondPeak = 0
        motion.startDeviceMotionUpdates(to: queue) { [weak self] deviceMotion, _ in
            guard let deviceMotion else { return }
            let acceleration = deviceMotion.userAcceleration
            let magnitude = sqrt(
                acceleration.x * acceleration.x +
                acceleration.y * acceleration.y +
                acceleration.z * acceleration.z
            )
            let rotation = deviceMotion.rotationRate
            let rotationMagnitude = sqrt(
                rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z
            )
            Task { @MainActor [weak self] in
                self?.process(magnitude: magnitude, rotation: rotationMagnitude)
            }
        }
        isMonitoring = true
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        isMonitoring = false
        resetExcursion()
        // Flush the second in progress so the last moments of a drive are not lost.
        if let start = secondStart { onSecondElapsed?(start, secondPeak) }
        secondStart = nil
        secondPeak = 0
    }

    func updateSensitivity(_ sensitivity: ShockSensitivity) {
        self.sensitivity = sensitivity
    }

    func setHarshBrakingDetection(_ enabled: Bool) {
        detectsHarshBraking = enabled
    }

    // MARK: - Detection

    /// Exposed (and pure) so the filter chain can be exercised by unit tests without a
    /// device: feed it a synthetic braking ramp and it must stay silent.
    func process(magnitude: Double, rotation: Double, now: Date = Date()) {
        currentMagnitude = magnitude
        accumulateSecond(magnitude: magnitude, now: now)
        let threshold = sensitivity.thresholdG
        let jerk = abs(magnitude - previousMagnitude)
        previousMagnitude = magnitude

        // The entry threshold opens the excursion window, so the rising edge is measured
        // rather than only the peak sample.
        //
        // It has to clear the *lower* of the two detectors, not just the impact one: at
        // 60% of 2.5 g an emergency stop at 0.6 g would never open an excursion at all,
        // and the braking path would be dead code. Opening more often costs nothing —
        // the impact path still requires its own peak before it fires.
        let entry = detectsHarshBraking
            ? min(threshold * 0.6, RecordingSettings.harshBrakingThresholdG * 0.8)
            : threshold * 0.6

        if magnitude >= entry {
            if excursionStart == nil {
                excursionStart = now
                excursionPeak = 0
                excursionSawSharpEdge = false
                excursionSawHandling = false
            }
            excursionPeak = max(excursionPeak, magnitude)
            if jerk >= jerkThreshold { excursionSawSharpEdge = true }
            if rotation >= handlingRotationThreshold { excursionSawHandling = true }

            // An excursion that runs on past what any single event can be is neither a
            // crash nor a stop — sustained vibration, or a rough road. Abandon it.
            if let start = excursionStart, now.timeIntervalSince(start) > maximumSustainedExcursion {
                resetExcursion()
            }
            return
        }

        // Falling edge — decide.
        guard let start = excursionStart else { return }
        let duration = now.timeIntervalSince(start)
        let peak = excursionPeak
        let sharp = excursionSawSharpEdge
        let handled = excursionSawHandling
        resetExcursion()

        // A long, smooth excursion that never spiked is an emergency stop, not a crash.
        if !sharp, !handled,
           duration >= RecordingSettings.harshBrakingMinimumDuration,
           peak >= RecordingSettings.harshBrakingThresholdG {
            reportBraking(peak: peak, duration: duration, now: now)
            return
        }

        guard peak >= threshold, sharp, !handled, duration <= maximumExcursion else { return }
        if let last = lastEventDate, now.timeIntervalSince(last) < cooldown { return }

        lastEventDate = now
        let event = ImpactEvent(date: now, magnitude: peak)
        lastImpact = event
        Log.motion.info("Impact detected at \(peak, privacy: .public) g")
        onImpact?(event)
    }

    private func reportBraking(peak: Double, duration: TimeInterval, now: Date) {
        guard detectsHarshBraking else { return }
        if let last = lastBrakingDate, now.timeIntervalSince(last) < cooldown { return }
        lastBrakingDate = now
        Log.motion.info("Harsh braking detected at \(peak, privacy: .public) g over \(duration, privacy: .public) s")
        onHarshBraking?(HarshBrakingEvent(date: now, magnitude: peak, duration: duration))
    }

    /// Rolls the per-second peak. The window is wall-clock rather than a sample count so
    /// a dropped batch of readings shortens a second instead of shifting every one after.
    private func accumulateSecond(magnitude: Double, now: Date) {
        guard let start = secondStart else {
            secondStart = now
            secondPeak = magnitude
            return
        }
        secondPeak = max(secondPeak, magnitude)
        guard now.timeIntervalSince(start) >= 1 else { return }
        onSecondElapsed?(start, secondPeak)
        secondStart = now
        secondPeak = magnitude
    }

    private func resetExcursion() {
        excursionStart = nil
        excursionPeak = 0
        excursionSawSharpEdge = false
        excursionSawHandling = false
    }
}
