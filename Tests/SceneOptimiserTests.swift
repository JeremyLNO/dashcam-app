import AVFoundation
import XCTest
@testable import Dashcam

/// The scene classifier decides how the road is exposed, so its boundaries are worth
/// pinning down. They are tested on the borders themselves, not in the comfortable middle
/// of each band — a threshold is only ever wrong at its edge.
final class SceneOptimiserTests: XCTestCase {
    private let optimiser = SceneOptimiser(queue: DispatchQueue(label: "test.scene"))

    func testADarkRoadIsRecognisedByItsISO() {
        XCTAssertEqual(optimiser.classify(iso: 1_000, shutterSeconds: 1.0 / 120, current: .neutral), .dark, "ISO 1000 is the boundary and counts as dark")
        XCTAssertEqual(optimiser.classify(iso: 2_400, shutterSeconds: 1.0 / 120, current: .neutral), .dark)
    }

    /// The shutter alone is enough: a camera that has already slowed down is in the dark,
    /// whatever its ISO says.
    func testALongShutterIsDarkEvenAtLowISO() {
        XCTAssertEqual(optimiser.classify(iso: 200, shutterSeconds: 1.0 / 45, current: .neutral), .dark)
        XCTAssertEqual(optimiser.classify(iso: 200, shutterSeconds: 1.0 / 30, current: .neutral), .dark)
    }

    func testSnowAndLowSunReadAsBright() {
        XCTAssertEqual(optimiser.classify(iso: 60, shutterSeconds: 1.0 / 2_000, current: .neutral), .bright, "ISO 60 is the boundary and counts as bright")
        XCTAssertEqual(optimiser.classify(iso: 25, shutterSeconds: 1.0 / 4_000, current: .neutral), .bright)
    }

    func testOrdinaryDaylightIsLeftAlone() {
        XCTAssertEqual(optimiser.classify(iso: 200, shutterSeconds: 1.0 / 500, current: .neutral), .neutral)
        XCTAssertEqual(optimiser.classify(iso: 999, shutterSeconds: 1.0 / 200, current: .neutral), .neutral, "just under the dark boundary")
        XCTAssertEqual(optimiser.classify(iso: 61, shutterSeconds: 1.0 / 1_000, current: .neutral), .neutral, "just over the bright boundary")
    }

    // MARK: - The loop that cut the picture four times a second

    /// The defect, stated as a test: **the cap that `.dark` applies makes the shutter
    /// faster than the threshold that chose `.dark`.**
    ///
    /// With a single threshold, the very next reading said « not dark », the cap came off,
    /// the shutter lengthened, and it said « dark » again — at the timer's 4 Hz, each flip
    /// locking a running camera for configuration, which the picture shows. Reported as
    /// « the video stream keeps cutting out and there is no interruption ».
    func testTheDarkSceneSurvivesTheShutterCapItJustApplied() {
        let capped = CMTimeGetSeconds(SceneOptimiser.darkShutterCap)
        XCTAssertLessThan(capped, 1.0 / 45,
                          "the cap is faster than the entry threshold — that is the whole trap")
        XCTAssertEqual(
            optimiser.classify(iso: 900, shutterSeconds: capped, current: .dark), .dark,
            "a reading taken through our own cap must not be read as the world getting lighter"
        )
    }

    /// And it does end — on the light itself, which the cap does not touch, and only once
    /// the light is clearly back.
    func testTheDarkSceneEndsWhenTheLightReallyReturns() {
        let capped = CMTimeGetSeconds(SceneOptimiser.darkShutterCap)
        XCTAssertEqual(optimiser.classify(iso: 800, shutterSeconds: capped, current: .dark), .dark,
                       "800 is inside the band the two thresholds leave between them")
        XCTAssertEqual(optimiser.classify(iso: 700, shutterSeconds: capped, current: .dark), .neutral)
        XCTAssertEqual(optimiser.classify(iso: 50, shutterSeconds: capped, current: .dark), .bright)
    }

    /// The same gap on the other side, so a scene hovering on the bright boundary does not
    /// flicker either.
    func testTheBrightSceneHasItsOwnGap() {
        XCTAssertEqual(optimiser.classify(iso: 61, shutterSeconds: 1.0 / 1_000, current: .bright), .bright)
        XCTAssertEqual(optimiser.classify(iso: 119, shutterSeconds: 1.0 / 1_000, current: .bright), .bright)
        XCTAssertEqual(optimiser.classify(iso: 120, shutterSeconds: 1.0 / 1_000, current: .neutral), .neutral)
    }

    /// Entering still costs the full distance: hysteresis widens the bands, it does not
    /// move them.
    func testEnteringIsUnchangedByTheHysteresis() {
        XCTAssertEqual(optimiser.classify(iso: 999, shutterSeconds: 1.0 / 200, current: .neutral), .neutral)
        XCTAssertEqual(optimiser.classify(iso: 1_000, shutterSeconds: 1.0 / 200, current: .neutral), .dark)
    }

    /// Belt and braces: even a genuine flicker — a hedge across a low sun — costs one
    /// change, not four a second. Each one locks a running camera.
    func testSceneChangesAreRationed() {
        XCTAssertGreaterThanOrEqual(SceneOptimiser.minimumDwell, 1)
        XCTAssertLessThanOrEqual(SceneOptimiser.minimumDwell, 10,
                                 "past this, a tunnel is over before the camera reacts")
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
