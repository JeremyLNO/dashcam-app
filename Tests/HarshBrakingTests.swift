import XCTest
@testable import Dashcam

/// Harsh braking and impact share one signal and must never be confused for each other.
@MainActor
final class HarshBrakingTests: XCTestCase {
    private var motion: MotionManager!
    private var impacts: [ImpactEvent] = []
    private var brakings: [HarshBrakingEvent] = []

    override func setUp() async throws {
        motion = MotionManager()
        impacts = []
        brakings = []
        motion.onImpact = { [weak self] in self?.impacts.append($0) }
        motion.onHarshBraking = { [weak self] in self?.brakings.append($0) }
        motion.updateSensitivity(.normal)
        motion.setHarshBrakingDetection(true)
    }

    private func feed(_ samples: [(Double, Double)], from t0: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        for (offset, sample) in samples.enumerated() {
            motion.process(magnitude: sample.0, rotation: sample.1, now: t0.addingTimeInterval(Double(offset) / 50))
        }
    }

    /// An emergency stop: climbs gently to `peak`, holds, fades. No single step anywhere.
    ///
    /// The hold is deliberately generous (0.6 s). The detector requires the excursion to
    /// stay above its entry level for at least `harshBrakingMinimumDuration`, so a short
    /// hold would make every test here secretly about duration rather than about the
    /// thing it claims to measure.
    private func emergencyStop(peak: Double = 0.6) -> [(Double, Double)] {
        var samples: [(Double, Double)] = [(0.02, 0.05)]
        for i in 1...12 { samples.append((peak * Double(i) / 12, 0.08)) }   // 0.24 s ramp up
        samples += Array(repeating: (peak, 0.08), count: 30)                // 0.60 s hold
        for i in stride(from: 12, through: 1, by: -1) { samples.append((peak * Double(i) / 12, 0.08)) }
        samples.append((0.02, 0.05))
        return samples
    }

    func testAnEmergencyStopFiresBrakingAndNotImpact() throws {
        feed(emergencyStop())

        XCTAssertEqual(brakings.count, 1)
        XCTAssertTrue(impacts.isEmpty, "a ramp is not a collision")
        let event = try XCTUnwrap(brakings.first)
        XCTAssertGreaterThanOrEqual(event.magnitude, RecordingSettings.harshBrakingThresholdG)
        XCTAssertGreaterThanOrEqual(event.duration, RecordingSettings.harshBrakingMinimumDuration)
    }

    func testACollisionFiresImpactAndNotBraking() {
        feed([(0.05, 0.1), (0.06, 0.1), (3.4, 0.2), (2.2, 0.2), (0.2, 0.1), (0.05, 0.1)])

        XCTAssertEqual(impacts.count, 1)
        XCTAssertTrue(brakings.isEmpty, "a step is not a stop")
    }

    /// Ordinary city braking sits well under the threshold and must stay silent.
    func testGentleBrakingStaysSilent() {
        feed(emergencyStop(peak: 0.25))

        XCTAssertTrue(brakings.isEmpty)
        XCTAssertTrue(impacts.isEmpty)
    }

    /// The boundary itself: just under the threshold is silence, just over is an event.
    func testBrakingThresholdIsExactlyOnTheBoundary() {
        feed(emergencyStop(peak: RecordingSettings.harshBrakingThresholdG - 0.02))
        XCTAssertTrue(brakings.isEmpty, "below the threshold")

        feed(emergencyStop(peak: RecordingSettings.harshBrakingThresholdG + 0.02),
             from: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(brakings.count, 1, "above the threshold")
    }

    /// Holding just below the entry level is not an excursion at all, so a long but
    /// gentle slowdown never even reaches the amplitude test.
    func testASlowdownBelowTheEntryLevelNeverOpensAnExcursion() {
        feed(emergencyStop(peak: RecordingSettings.harshBrakingThresholdG * 0.7))
        XCTAssertTrue(brakings.isEmpty)
        XCTAssertTrue(impacts.isEmpty)
    }

    /// A hard but *brief* deceleration — a pothole-like jolt — is not a stop.
    func testABriefDecelerationIsNotBraking() {
        var samples: [(Double, Double)] = [(0.02, 0.05)]
        for i in 1...5 { samples.append((0.6 * Double(i) / 5, 0.08)) }   // 0.1 s only
        samples.append((0.02, 0.05))

        feed(samples)
        XCTAssertTrue(brakings.isEmpty, "too short to be an emergency stop")
    }

    func testBrakingRespectsTheCooldown() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        feed(emergencyStop(), from: t0)
        feed(emergencyStop(), from: t0.addingTimeInterval(3))

        XCTAssertEqual(brakings.count, 1)
    }

    func testDisablingBrakingDetectionSilencesItWithoutAffectingImpacts() {
        motion.setHarshBrakingDetection(false)
        feed(emergencyStop())
        XCTAssertTrue(brakings.isEmpty)

        feed([(0.05, 0.1), (3.4, 0.2), (0.1, 0.1)], from: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(impacts.count, 1, "impacts are unaffected")
    }

    /// Being handled looks like braking in amplitude; the gyroscope is what separates them.
    func testHandlingTheDeviceIsNotReportedAsBraking() {
        var samples = emergencyStop()
        samples = samples.map { ($0.0, $0.0 > 0.1 ? 4.0 : $0.1) }

        feed(samples)
        XCTAssertTrue(brakings.isEmpty)
    }

    // MARK: G-force history

    func testPeakPerSecondIsReportedOncePerSecond() {
        var samples: [(Date, Double)] = []
        motion.onSecondElapsed = { samples.append(($0, $1)) }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Three seconds at 50 Hz, with a distinct peak in the second one.
        for i in 0..<150 {
            let magnitude = i == 75 ? 1.4 : 0.05
            motion.process(magnitude: magnitude, rotation: 0.05, now: t0.addingTimeInterval(Double(i) / 50))
        }

        XCTAssertEqual(samples.count, 2, "two whole seconds elapsed, the third is still open")
        XCTAssertEqual(samples[1].1, 1.4, accuracy: 0.001, "the peak lands in the second it happened")
        XCTAssertEqual(samples[0].1, 0.05, accuracy: 0.001)
    }
}
