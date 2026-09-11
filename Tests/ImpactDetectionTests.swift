import XCTest
@testable import Dashcam

/// The false-positive filters. Each test here is a driving situation the detector must
/// stay silent through.
@MainActor
final class ImpactDetectionTests: XCTestCase {
    private var motion: MotionManager!
    private var events: [ImpactEvent] = []

    override func setUp() async throws {
        motion = MotionManager()
        events = []
        motion.onImpact = { [weak self] event in self?.events.append(event) }
        motion.updateSensitivity(.normal)
    }

    /// Feeds a series of (magnitude, rotation) samples at 50 Hz starting from `t0`.
    private func feed(_ samples: [(Double, Double)], from t0: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        for (offset, sample) in samples.enumerated() {
            motion.process(magnitude: sample.0, rotation: sample.1, now: t0.addingTimeInterval(Double(offset) / 50))
        }
    }

    func testASharpBriefSpikeFires() {
        // Quiet, one-sample step well past 2.5 g, quiet again.
        feed([(0.05, 0.1), (0.06, 0.1), (3.4, 0.2), (2.2, 0.2), (0.2, 0.1), (0.05, 0.1)])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.magnitude ?? 0, 3.4, accuracy: 0.001)
    }

    /// Hard braking is a ramp: it climbs over hundreds of milliseconds, so the jerk
    /// filter never sees a step.
    func testHardBrakingDoesNotFire() {
        var samples: [(Double, Double)] = [(0.05, 0.05)]
        // 0 -> 3.0 g over 40 samples (0.8 s), i.e. 0.075 g per sample.
        for i in 1...40 { samples.append((Double(i) * 0.075, 0.05)) }
        for i in stride(from: 40, through: 1, by: -1) { samples.append((Double(i) * 0.075, 0.05)) }
        samples.append((0.02, 0.05))

        feed(samples)
        XCTAssertTrue(events.isEmpty, "a braking ramp is neither sharp nor brief")
    }

    /// A speed bump is sharp and brief, but the phone is not being rotated — so it fires
    /// unless it stays under the amplitude threshold. At "low" sensitivity it must not.
    func testSpeedBumpStaysBelowTheLowSensitivityThreshold() {
        motion.updateSensitivity(.low)   // 3.5 g
        feed([(0.05, 0.1), (2.6, 0.3), (1.1, 0.2), (0.1, 0.1)])
        XCTAssertTrue(events.isEmpty)
    }

    /// The same bump at high sensitivity is meant to fire — that is what the setting is
    /// for.
    func testSpeedBumpFiresAtHighSensitivity() {
        motion.updateSensitivity(.high)  // 1.8 g
        feed([(0.05, 0.1), (2.6, 0.3), (1.1, 0.2), (0.1, 0.1)])
        XCTAssertEqual(events.count, 1)
    }

    /// Picking the phone up produces the same amplitude as a light knock, but it comes
    /// with rotation. That is the discriminator.
    func testHandlingTheDeviceIsRejected() {
        feed([(0.05, 0.1), (3.6, 4.2), (2.0, 3.8), (0.1, 1.0)])
        XCTAssertTrue(events.isEmpty, "gyroscope showed the device was being handled")
    }

    /// Sustained shaking exceeds the threshold repeatedly but never returns to rest
    /// inside the brevity window.
    func testSustainedVibrationIsAbandonedNotFired() {
        let samples = Array(repeating: (2.9, 0.4), count: 60)   // 1.2 s above the entry level
        feed([(0.05, 0.1)] + samples + [(0.05, 0.1)])
        XCTAssertTrue(events.isEmpty)
    }

    func testCooldownCollapsesOneCollisionIntoOneEvent() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        feed([(0.05, 0.1), (3.4, 0.2), (0.1, 0.1)], from: t0)
        // A second spike two seconds later — the same crash still resonating.
        feed([(0.05, 0.1), (3.9, 0.2), (0.1, 0.1)], from: t0.addingTimeInterval(2))

        XCTAssertEqual(events.count, 1)
    }

    func testASecondCollisionAfterTheCooldownFiresAgain() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        feed([(0.05, 0.1), (3.4, 0.2), (0.1, 0.1)], from: t0)
        feed([(0.05, 0.1), (3.9, 0.2), (0.1, 0.1)], from: t0.addingTimeInterval(15))

        XCTAssertEqual(events.count, 2)
    }

    func testSensitivityThresholdsAreOrderedFromStrictToLoose() {
        XCTAssertGreaterThan(ShockSensitivity.low.thresholdG, ShockSensitivity.normal.thresholdG)
        XCTAssertGreaterThan(ShockSensitivity.normal.thresholdG, ShockSensitivity.high.thresholdG)
    }
}
