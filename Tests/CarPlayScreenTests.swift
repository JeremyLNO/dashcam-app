import XCTest
@testable import Dashcam

/// Which of the three CarPlay screens is showing, and — the part that matters at 90 km/h —
/// which buttons are *not* on it.
///
/// The interface answers one question: what can I do right now? Every rule below exists so
/// that the answer never needs reading twice.
final class CarPlayScreenTests: XCTestCase {
    private func status(mode: CaptureMode = .dual, frontActive: Bool = true,
                        isRunning: Bool = true, interruption: CaptureInterruption? = nil) -> CaptureStatus {
        CaptureStatus(mode: mode, hasBeenConfigured: true, isRunning: isRunning,
                      rearActive: mode != .unavailable, frontActive: frontActive,
                      interruption: interruption)
    }

    private func screen(isRecording: Bool = false, status: CaptureStatus, isDiscreet: Bool = false) -> CarPlayScreen {
        CarPlayScreen.decide(
            isRecording: isRecording,
            readiness: RecordingReadiness.assess(status),
            camerasKey: CarPlayDashboard.camerasKey(status: status),
            isDiscreet: isDiscreet
        )
    }

    // MARK: - The rule the whole screen rests on

    /// START and STOP must never be offered at the same time. A driver who has to read a
    /// button before pressing it is a driver reading instead of driving.
    func testStartAndStopAreNeverBothOffered() {
        let ready = screen(status: status()).actions
        XCTAssertTrue(ready.contains(.start))
        XCTAssertFalse(ready.contains(.stop))

        let recording = screen(isRecording: true, status: status()).actions
        XCTAssertTrue(recording.contains(.stop))
        XCTAssertFalse(recording.contains(.start))
    }

    /// Protecting a clip means nothing before there is a clip.
    func testProtectIsOnlyOfferedDuringADrive() {
        XCTAssertFalse(screen(status: status()).actions.contains(.protectClip))
        XCTAssertTrue(screen(isRecording: true, status: status()).actions.contains(.protectClip))
    }

    // MARK: - Blocked

    /// The dominant state. Nothing else may share the screen with it — not a counter, not
    /// the storage, and above all not a button that cannot work.
    func testABlockedScreenOffersNothingAtAll() {
        let blocked = screen(status: status(isRunning: false, interruption: .notRunnableInBackground))
        XCTAssertEqual(blocked, .blocked(detailKey: "capture.interrupted.background"))
        XCTAssertEqual(blocked.actions, [], "a button that cannot work is pressed, and believed")
    }

    func testNoCameraIsBlockedToo() {
        let blocked = screen(status: status(mode: .unavailable, frontActive: false, isRunning: false))
        XCTAssertEqual(blocked.actions, [])
    }

    /// And the one exception, which is not an exception but a priority: a drive already
    /// running keeps its Stop button whatever the capture status claims. The footage is
    /// being written; taking Stop away because of a flag would be the worse failure.
    func testADriveInProgressKeepsItsButtonsWhateverTheStatusSays() {
        let recording = screen(isRecording: true, status: status(isRunning: false, interruption: .phoneCall))
        XCTAssertEqual(recording, .recording(isDiscreet: false))
        XCTAssertTrue(recording.actions.contains(.stop))
    }

    // MARK: - Ready

    func testTheReadyScreenLeadsWithOneAction() {
        let ready = screen(status: status())
        XCTAssertEqual(ready, .ready(camerasKey: "carplay.cameras.both"))
        XCTAssertEqual(ready.actions, [.start], "one button, and it dominates because it is alone")
    }

    func testTheCameraLineTellsTwoApartFromOne() {
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status()), "carplay.cameras.both")
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(frontActive: false)), "carplay.cameras.road",
                       "a dual-capable phone filming one camera must not claim two")
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(mode: .rearOnly, frontActive: false)), "carplay.cameras.road")
        XCTAssertEqual(CarPlayDashboard.camerasKey(status: status(mode: .unavailable, frontActive: false)), "carplay.cameras.none")
    }

    // MARK: - Recording

    func testTheRecordingScreenOffersStopProtectAndTheScreen() {
        XCTAssertEqual(
            screen(isRecording: true, status: status()).actions,
            [.stop, .protectClip, .discreet],
            "stop first: it is the one that is reached for in a hurry"
        )
    }

    /// The discreet button carries its own state, so the screen has to change when it does
    /// — otherwise the label says « dim » over an already dark phone.
    func testTheDiscreetStateIsPartOfTheScreen() {
        XCTAssertNotEqual(
            screen(isRecording: true, status: status(), isDiscreet: true),
            screen(isRecording: true, status: status(), isDiscreet: false)
        )
    }

    // MARK: - Confirmations

    /// Long enough to read at a glance, short enough that the screen is useful again before
    /// the next junction — and nothing to press either way.
    func testAConfirmationSaysItselfAndLeaves() {
        XCTAssertGreaterThanOrEqual(CarPlayConfirmation.duration, 1)
        XCTAssertLessThanOrEqual(CarPlayConfirmation.duration, 3)
        XCTAssertEqual(CarPlayConfirmation.clipProtected.titleKey, "carplay.confirm.protected")
        XCTAssertEqual(CarPlayConfirmation.driveSaved.titleKey, "carplay.confirm.saved")
    }
}
