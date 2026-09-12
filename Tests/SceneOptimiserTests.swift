import AVFoundation
import XCTest
@testable import Dashcam

/// The scene classifier decides how the road is exposed, so its boundaries are worth
/// pinning down. They are tested on the borders themselves, not in the comfortable middle
/// of each band — a threshold is only ever wrong at its edge.
final class SceneOptimiserTests: XCTestCase {
    private let optimiser = SceneOptimiser(queue: DispatchQueue(label: "test.scene"))

    func testADarkRoadIsRecognisedByItsISO() {
        XCTAssertEqual(optimiser.classify(iso: 1_000, shutterSeconds: 1.0 / 120), .dark, "ISO 1000 is the boundary and counts as dark")
        XCTAssertEqual(optimiser.classify(iso: 2_400, shutterSeconds: 1.0 / 120), .dark)
    }

    /// The shutter alone is enough: a camera that has already slowed down is in the dark,
    /// whatever its ISO says.
    func testALongShutterIsDarkEvenAtLowISO() {
        XCTAssertEqual(optimiser.classify(iso: 200, shutterSeconds: 1.0 / 45), .dark)
        XCTAssertEqual(optimiser.classify(iso: 200, shutterSeconds: 1.0 / 30), .dark)
    }

    func testSnowAndLowSunReadAsBright() {
        XCTAssertEqual(optimiser.classify(iso: 60, shutterSeconds: 1.0 / 2_000), .bright, "ISO 60 is the boundary and counts as bright")
        XCTAssertEqual(optimiser.classify(iso: 25, shutterSeconds: 1.0 / 4_000), .bright)
    }

    func testOrdinaryDaylightIsLeftAlone() {
        XCTAssertEqual(optimiser.classify(iso: 200, shutterSeconds: 1.0 / 500), .neutral)
        XCTAssertEqual(optimiser.classify(iso: 999, shutterSeconds: 1.0 / 200), .neutral, "just under the dark boundary")
        XCTAssertEqual(optimiser.classify(iso: 61, shutterSeconds: 1.0 / 1_000), .neutral, "just over the bright boundary")
    }

    /// The corrections point the right way: brighter on snow, never darker, and a dark
    /// scene lifted only slightly — a night road that is too bright is noise, not detail.
    func testTheBiasLeansTheWayEachSceneNeeds() {
        XCTAssertEqual(SceneOptimiser.Scene.neutral.exposureBias, 0)
        XCTAssertGreaterThan(SceneOptimiser.Scene.bright.exposureBias, SceneOptimiser.Scene.dark.exposureBias)
        XCTAssertGreaterThan(SceneOptimiser.Scene.dark.exposureBias, 0)
    }

    /// The shutter cap is the whole point of the dark case: 1/60 s is what keeps a moving
    /// plate from smearing.
    func testTheShutterCapStaysShortEnoughToReadAPlate() {
        XCTAssertLessThanOrEqual(CMTimeGetSeconds(SceneOptimiser.darkShutterCap), 1.0 / 60)
    }
}
