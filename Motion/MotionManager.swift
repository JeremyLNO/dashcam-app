import CoreMotion
import Foundation

/// A detected impact, with enough context to explain itself.
struct ImpactEvent: Equatable, Sendable {
    let date: Date
    /// Peak total acceleration, in g, excluding gravity.
    let magnitude: Double
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
@MainActor
final class MotionManager: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastImpact: ImpactEvent?
    /// Live magnitude, exposed for the Settings sensitivity screen so the user can see
    /// what their driving actually produces.
    @Published private(set) var currentMagnitude: Double = 0

    var onImpact: ((ImpactEvent) -> Void)?

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

    private var previousMagnitude: Double = 0
    private var excursionStart: Date?
    private var excursionPeak: Double = 0
    private var excursionSawSharpEdge = false
    private var excursionSawHandling = false
    private var lastEventDate: Date?

    init() {
        queue.name = "dashcam.lno.company.motion"
        queue.maxConcurrentOperationCount = 1
    }

    func start(sensitivity: ShockSensitivity) {
        self.sensitivity = sensitivity
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else {
            isMonitoring = motion.isDeviceMotionActive
            return
        }
        motion.deviceMotionUpdateInterval = 1 / sampleRate
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
    }

    func updateSensitivity(_ sensitivity: ShockSensitivity) {
        self.sensitivity = sensitivity
    }

    // MARK: - Detection

    /// Exposed (and pure) so the filter chain can be exercised by unit tests without a
    /// device: feed it a synthetic braking ramp and it must stay silent.
    func process(magnitude: Double, rotation: Double, now: Date = Date()) {
        currentMagnitude = magnitude
        let threshold = sensitivity.thresholdG
        let jerk = abs(magnitude - previousMagnitude)
        previousMagnitude = magnitude

        // A short entry threshold (60% of the trigger) opens the excursion window, so the
        // rising edge is measured rather than only the peak sample.
        let entry = threshold * 0.6

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

            // Sustained excursion: a manoeuvre. Abandon it without firing.
            if let start = excursionStart, now.timeIntervalSince(start) > maximumExcursion {
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

        guard peak >= threshold, sharp, !handled, duration <= maximumExcursion else { return }
        if let last = lastEventDate, now.timeIntervalSince(last) < cooldown { return }

        lastEventDate = now
        let event = ImpactEvent(date: now, magnitude: peak)
        lastImpact = event
        Log.motion.info("Impact detected at \(peak, privacy: .public) g")
        onImpact?(event)
    }

    private func resetExcursion() {
        excursionStart = nil
        excursionPeak = 0
        excursionSawSharpEdge = false
        excursionSawHandling = false
    }
}
