import CoreLocation
import XCTest
@testable import Dashcam

/// Distance is only as good as its rejection rules.
final class DistanceAccumulatorTests: XCTestCase {
    private func fix(lat: Double, lon: Double, accuracy: CLLocationAccuracy = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: Date()
        )
    }

    func testTheFirstFixContributesNothing() {
        var accumulator = DistanceAccumulator()
        XCTAssertEqual(accumulator.add(fix(lat: 48.85, lon: 2.35)), 0)
        XCTAssertEqual(accumulator.totalMetres, 0)
    }

    func testConsecutiveLegsAccumulate() {
        var accumulator = DistanceAccumulator()
        accumulator.add(fix(lat: 48.8500, lon: 2.3500))
        // ~111 m per 0.001° of latitude.
        accumulator.add(fix(lat: 48.8510, lon: 2.3500))
        accumulator.add(fix(lat: 48.8520, lon: 2.3500))

        XCTAssertEqual(accumulator.totalMetres, 222, accuracy: 5)
    }

    /// A parked car at a red light: GPS wanders a couple of metres a second. Summing that
    /// would invent hundreds of metres over a single stop.
    func testStationaryNoiseIsRejected() {
        var accumulator = DistanceAccumulator()
        accumulator.add(fix(lat: 48.85, lon: 2.35))
        for _ in 0..<60 {
            // ~2 m jitter, back and forth.
            accumulator.add(fix(lat: 48.850018, lon: 2.35))
            accumulator.add(fix(lat: 48.85, lon: 2.35))
        }
        XCTAssertEqual(accumulator.totalMetres, 0, "noise below the floor contributes nothing")
    }

    /// A tunnel exit or a cold start teleports the fix. That is a re-acquisition, not
    /// movement.
    func testImplausibleJumpsAreRejected() {
        var accumulator = DistanceAccumulator()
        accumulator.add(fix(lat: 48.85, lon: 2.35))
        accumulator.add(fix(lat: 48.90, lon: 2.35))   // ~5.5 km in one step

        XCTAssertEqual(accumulator.totalMetres, 0)
    }

    func testImpreciseFixesAreIgnoredWithoutPoisoningTheAnchor() {
        var accumulator = DistanceAccumulator()
        accumulator.add(fix(lat: 48.8500, lon: 2.3500))
        accumulator.add(fix(lat: 48.8600, lon: 2.3500, accuracy: 300))   // junk, dropped
        accumulator.add(fix(lat: 48.8510, lon: 2.3500))                  // measured from the good anchor

        XCTAssertEqual(accumulator.totalMetres, 111, accuracy: 5)
    }

    /// Exactly on each boundary, because that is where an off-by-one lives.
    func testLegBoundariesAreInclusive() {
        XCTAssertEqual(DistanceAccumulator.minimumLegMetres, 5)
        XCTAssertEqual(DistanceAccumulator.maximumLegMetres, 1000)

        var accumulator = DistanceAccumulator()
        accumulator.add(fix(lat: 48.85, lon: 2.35))
        // 0.000045° of latitude ≈ 5.0 m.
        let contributed = accumulator.add(fix(lat: 48.850045, lon: 2.35))
        XCTAssertGreaterThan(contributed, 0, "a leg exactly at the floor counts")
    }

    func testResetClearsBothTotalAndAnchor() {
        var accumulator = DistanceAccumulator()
        accumulator.add(fix(lat: 48.8500, lon: 2.35))
        accumulator.add(fix(lat: 48.8510, lon: 2.35))
        accumulator.reset()

        XCTAssertEqual(accumulator.totalMetres, 0)
        XCTAssertEqual(accumulator.add(fix(lat: 48.8520, lon: 2.35)), 0, "the anchor is gone too")
    }
}
