import XCTest
@testable import Dashcam

/// When the cameras are allowed to hold the video pipeline.
///
/// They used to hold it for as long as the app was on screen — two cameras filming a pocket
/// while the driver watched footage back in the library. That is a battery cost on its own,
/// and it is the leading explanation for the two-up playback coming back black on the
/// phone: road and cabin together need two decoders, and a multi-camera capture session
/// already has the pipeline. Nothing reports a refusal; the frames simply never arrive.
final class CapturePresenceTests: XCTestCase {
    func testTheCamerasRunForTheScreenThatShowsThem() {
        XCTAssertTrue(CapturePresence.shouldRun(isRecording: false, isShowingCameras: true, isForeground: true))
    }

    /// The change: the library no longer competes with itself.
    func testTheCamerasStopWhileFootageIsBeingWatched() {
        XCTAssertFalse(
            CapturePresence.shouldRun(isRecording: false, isShowingCameras: false, isForeground: true),
            "two cameras filming nothing while two more streams are being decoded"
        )
    }

    /// The rule that must never break: a drive outranks everything. Switching to the
    /// library mid-drive stopping the recording would be far worse than the defect this
    /// fixes.
    func testADriveKeepsTheCamerasWhateverIsOnScreen() {
        XCTAssertTrue(CapturePresence.shouldRun(isRecording: true, isShowingCameras: false, isForeground: true))
    }

    /// iOS suspends capture in the background whatever the app asks for; asking anyway only
    /// spends the wake-up — and, for a drive, is the lie this session started from.
    func testNothingRunsInTheBackground() {
        XCTAssertFalse(CapturePresence.shouldRun(isRecording: true, isShowingCameras: true, isForeground: false))
        XCTAssertFalse(CapturePresence.shouldRun(isRecording: false, isShowingCameras: true, isForeground: false))
    }
}
