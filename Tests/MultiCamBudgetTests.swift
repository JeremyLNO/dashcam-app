import XCTest
@testable import Dashcam

/// The number Apple says you must respect and this app measured for months without ever
/// reading. Above 1.0 an `AVCaptureMultiCamSession` does not run — and it does not say so:
/// it starts, reports itself running, raises nothing, and delivers no frames. The preview
/// stays on its last picture.
final class MultiCamBudgetTests: XCTestCase {
    func testAConfigurationInsideTheBudgetIsLeftAlone() {
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 0.8, currentFrameRate: 30), .accept)
    }

    /// The boundary, and it is not academic: phones land exactly on it. Shedding a camera
    /// there would lose the cabin for nothing.
    func testExactlyOneFits() {
        XCTAssertTrue(MultiCamBudget.fits(1.0))
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.0, currentFrameRate: 30), .accept)
        XCTAssertFalse(MultiCamBudget.fits(1.0001))
    }

    /// Frame rate goes first, because it is the cheapest thing to lose. A dashcam at 24 fps
    /// is a dashcam; a dashcam showing a still image is not.
    func testTooExpensiveWalksTheFrameRateDown() {
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.4, currentFrameRate: 30), .lowerFrameRate(24))
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.4, currentFrameRate: 24), .lowerFrameRate(20))
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.4, currentFrameRate: 20), .lowerFrameRate(15))
    }

    /// And stops at the floor rather than walking to zero: below 15 fps the footage stops
    /// showing what happened between two frames, which is the whole job.
    func testTheFloorIsTheEndOfTheLadder() {
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.4, currentFrameRate: 15), .dropCabinCamera)
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 3.0, currentFrameRate: 12), .dropCabinCamera,
                       "a rate already below the ladder has nothing left to give either")
    }

    /// A rate the driver chose that is not on the ladder still has to walk down it.
    func testARateOffTheLadderStillFindsTheNextOneBelow() {
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.2, currentFrameRate: 60), .lowerFrameRate(30))
        XCTAssertEqual(MultiCamBudget.nextStep(cost: 1.2, currentFrameRate: 25), .lowerFrameRate(24))
    }
}
