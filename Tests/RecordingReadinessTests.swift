import XCTest
@testable import Dashcam

/// The defect this pins was reported from the car, and it is the worst shape a dashcam
/// defect can take: **the app said it was recording, and recorded nothing.**
///
/// START pressed on the CarPlay screen with the iPhone locked. iOS suspends camera capture
/// for any app that is not foreground on the phone itself, and a CarPlay scene does not
/// count as that. Every other part went on working — a session row, open writers, a
/// duration ticking on the car's screen, a template reading RECORDING — while not one frame
/// arrived and not one file was written. It is discovered afterwards, by someone looking
/// for footage of an accident.
final class RecordingReadinessTests: XCTestCase {
    private func status(
        mode: CaptureMode = .dual,
        isRunning: Bool = true,
        interruption: CaptureInterruption? = nil,
        unavailability: CaptureUnavailability? = nil
    ) -> CaptureStatus {
        CaptureStatus(
            mode: mode, unavailability: unavailability, isRunning: isRunning,
            rearActive: mode != .unavailable, frontActive: mode == .dual,
            interruption: interruption
        )
    }

    // MARK: - Before the drive is created

    func testAWorkingCameraIsReady() {
        XCTAssertEqual(RecordingReadiness.assess(status()), .ready)
        XCTAssertEqual(RecordingReadiness.assess(status(mode: .rearOnly)), .ready)
    }

    /// The one from the car. The phone is locked, iOS has taken the cameras away, and the
    /// message has to name the gesture that gives them back.
    func testALockedPhoneBlocksTheDriveRatherThanFakingIt() {
        let verdict = RecordingReadiness.assess(status(isRunning: false, interruption: .notRunnableInBackground))
        XCTAssertEqual(
            verdict,
            .blocked(titleKey: "alert.camera_unavailable.title", messageKey: "capture.interrupted.background")
        )
        XCTAssertFalse(verdict.isReady)
    }

    /// Any interruption, not only that one: a phone call and a thermal cut-off deliver
    /// exactly as many frames.
    func testEveryInterruptionBlocksTheDrive() {
        for interruption in [CaptureInterruption.phoneCall, .takenByAnotherApp,
                             .videoDeviceTemporarilyUnavailable, .systemPressure,
                             .sensitiveContentBlocked, .unknown] {
            let verdict = RecordingReadiness.assess(status(interruption: interruption))
            XCTAssertFalse(verdict.isReady, "\(interruption) let a drive start")
            XCTAssertEqual(verdict.messageKey, interruption.messageKey,
                           "the driver is owed the reason, not a generic failure")
        }
    }

    /// A session that is simply not running says nothing about why, and still delivers
    /// nothing. « No error posted » is not evidence of a working camera.
    func testASessionThatIsNotRunningBlocksTheDrive() {
        XCTAssertEqual(
            RecordingReadiness.assess(status(isRunning: false)),
            .blocked(titleKey: "alert.camera_unavailable.title", messageKey: "capture.error.not_running")
        )
    }

    func testNoCameraKeepsItsOwnExplanation() {
        XCTAssertEqual(
            RecordingReadiness.assess(status(mode: .unavailable, isRunning: false, unavailability: .simulator)),
            .blocked(titleKey: "alert.camera_unavailable.title", messageKey: "capture.error.simulator")
        )
    }

    // MARK: - Once the drive is running

    /// The belt that does not take iOS at its word: every check above can pass and no frame
    /// still arrive.
    func testADriveWithNoFrameAtAllIsNotRecording() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(RecordingReadiness.hasReceivedFootage(startedAt: start, lastFrame: nil))
    }

    /// A frame from *before* the drive began proves nothing about the drive — and it is the
    /// frame that is always there, since the preview was live until the phone locked.
    func testAFrameFromBeforeTheDriveDoesNotCount() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(RecordingReadiness.hasReceivedFootage(
            startedAt: start, lastFrame: start.addingTimeInterval(-0.5)
        ), "the last frame of the preview is not the first frame of the drive")
    }

    func testAFrameFromTheDriveCounts() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(RecordingReadiness.hasReceivedFootage(
            startedAt: start, lastFrame: start.addingTimeInterval(0.03)
        ))
    }

    /// Generous by two orders of magnitude — the preview is already delivering frames when
    /// Start is pressed — and still short enough to bound the lie to a few seconds.
    func testTheGraceIsShortEnoughToMatter() {
        XCTAssertGreaterThan(RecordingReadiness.firstFrameGrace, 1)
        XCTAssertLessThanOrEqual(RecordingReadiness.firstFrameGrace, 10)
    }
}
