import XCTest
@testable import Dashcam

/// What the car's screen says, checked away from CarPlay itself.
///
/// These lines are the ones that were wrong: a screen reading RECORDING over a drive that
/// was writing nothing, and a screen that could only say « Stopped » when what the driver
/// needed was the one gesture that would fix it.
final class CarPlayDashboardTests: XCTestCase {
    private func status(mode: CaptureMode, frontActive: Bool = false) -> CaptureStatus {
        CaptureStatus(mode: mode, isRunning: mode != .unavailable,
                      rearActive: mode != .unavailable, frontActive: frontActive)
    }

    func testAReadyCameraSimplySaysStopped() {
        XCTAssertEqual(
            CarPlayDashboard.stoppedStatusKey(readiness: .ready, interruption: nil),
            "carplay.stopped"
        )
    }

    /// The line that replaces a Start button which could not have worked.
    func testALockedPhoneIsToldWhatToDo() {
        XCTAssertEqual(
            CarPlayDashboard.stoppedStatusKey(
                readiness: .blocked(titleKey: "t", messageKey: "capture.interrupted.background"),
                interruption: .notRunnableInBackground
            ),
            "carplay.blocked.locked"
        )
    }

    func testOtherInterruptionsSayTheCameraIsBusy() {
        XCTAssertEqual(
            CarPlayDashboard.stoppedStatusKey(
                readiness: .blocked(titleKey: "t", messageKey: "capture.interrupted.call"),
                interruption: .phoneCall
            ),
            "carplay.blocked.paused"
        )
    }

    func testNoCameraAtAllSaysSo() {
        XCTAssertEqual(
            CarPlayDashboard.stoppedStatusKey(
                readiness: .blocked(titleKey: "t", messageKey: "capture.error.no_camera"),
                interruption: nil
            ),
            "carplay.blocked.no_camera"
        )
    }

    /// Which cameras are filming is worth a line of its own: a drive recorded with the
    /// cabin camera shed for heat looks identical from the driver's seat.
    func testTheCameraLineTellsTheTwoApartFromOne() {
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(mode: .dual, frontActive: true)), "carplay.cameras.both")
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(mode: .dual, frontActive: false)), "carplay.cameras.road",
                       "a dual-capable phone filming one camera must not claim two")
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(mode: .rearOnly)), "carplay.cameras.road")
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(mode: .unavailable)), "carplay.cameras.none")
    }
}
