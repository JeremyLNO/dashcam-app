import AVFoundation
import XCTest
@testable import Dashcam

/// What happens when another app takes the microphone.
///
/// Reported from the road: « the video stream is interrupted regularly », with a modal
/// reading *Recording interrupted: a phone call is using the microphone* — while both
/// previews carried on showing the road and the cabin perfectly.
///
/// `audioDeviceInUseByAnotherClient` is the odd interruption out, and its old name here
/// hid that: it fires whenever **any** other client wants the microphone — Siri, a voice
/// memo, a navigation app speaking a turn, a Bluetooth handset connecting. The cameras keep
/// running throughout. Treating it like the others ended the drive every time the map
/// spoke: the road was lost to protect the sound, which is the wrong way round for a
/// dashcam.
final class AudioInterruptionTests: XCTestCase {

    // MARK: - Which interruptions concern the cameras

    func testOnlyTheMicrophoneOneSparesTheVideo() {
        XCTAssertFalse(CaptureInterruption.phoneCall.affectsVideo,
                       "the cameras keep running while another app holds the microphone")
        for interruption in [CaptureInterruption.takenByAnotherApp, .notRunnableInBackground,
                             .videoDeviceTemporarilyUnavailable, .systemPressure,
                             .sensitiveContentBlocked, .unknown] {
            XCTAssertTrue(interruption.affectsVideo, "\(interruption) does stop the pictures")
        }
    }

    func testTheMicrophoneReasonStillMapsToTheMicrophoneCase() {
        XCTAssertEqual(CaptureInterruption(reason: .audioDeviceInUseByAnotherClient), .phoneCall)
        XCTAssertEqual(CaptureInterruption(reason: .videoDeviceInUseByAnotherClient), .takenByAnotherApp)
    }

    // MARK: - And what that means for starting a drive

    private func status(interruption: CaptureInterruption?) -> CaptureStatus {
        CaptureStatus(mode: .dual, isRunning: true, rearActive: true, frontActive: true,
                      interruption: interruption)
    }

    /// The consequence that made this worse than cosmetic: since readiness started
    /// refusing on any interruption, a borrowed microphone refused the drive outright.
    func testADriveIsNotRefusedBecauseAnotherAppIsUsingTheMicrophone() {
        XCTAssertEqual(
            RecordingReadiness.assess(status(interruption: .phoneCall)), .ready,
            "a drive refused because a map spoke a turn is a drive that was not filmed"
        )
    }

    func testADriveIsStillRefusedWhenTheCamerasAreActuallyGone() {
        XCTAssertFalse(RecordingReadiness.assess(status(interruption: .takenByAnotherApp)).isReady)
        XCTAssertFalse(RecordingReadiness.assess(status(interruption: .systemPressure)).isReady)
    }

    /// And the cards keep reading the frames, which are still arriving.
    func testTheCameraCardsAreUnaffectedByAMicrophoneInterruption() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            CameraSignal.assess(isActive: true, isRunning: true,
                                lastFrame: startedAt.addingTimeInterval(9.9),
                                startedRunningAt: startedAt, now: startedAt.addingTimeInterval(10)),
            .live
        )
    }
}
