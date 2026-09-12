import AVFoundation
import XCTest
@testable import Dashcam

/// Which interruptions the app waits out, and which it accepts as final.
///
/// The distinction decides whether a drive silently ends. A phone call took the camera
/// away and the recording stopped for good: the app looked normal, the road was no longer
/// being filmed, and the only sign had been an alert already dismissed.
final class InterruptionResumeTests: XCTestCase {
    func testTheInterruptionsThatEndOnTheirOwnAreWaitedOut() {
        for interruption in [CaptureInterruption.phoneCall, .takenByAnotherApp, .videoDeviceTemporarilyUnavailable, .systemPressure] {
            XCTAssertTrue(interruption.isTemporary, "\(interruption) comes back, so the drive should resume")
        }
    }

    /// Waiting for these would be waiting forever: the camera is not coming back without
    /// the user doing something first.
    func testTheInterruptionsThatNeedTheUserAreNotWaitedOut() {
        for interruption in [CaptureInterruption.notRunnableInBackground, .sensitiveContentBlocked, .unknown] {
            XCTAssertFalse(interruption.isTemporary, "\(interruption) must not resume by itself")
        }
    }

    /// The mapping from AVFoundation's reasons: a call and another app borrowing the
    /// camera are the two that happen on an ordinary drive.
    func testAVFoundationReasonsMapToTheRightInterruption() {
        XCTAssertEqual(CaptureInterruption(reason: .audioDeviceInUseByAnotherClient), .phoneCall)
        XCTAssertEqual(CaptureInterruption(reason: .videoDeviceInUseByAnotherClient), .takenByAnotherApp)
        XCTAssertEqual(CaptureInterruption(reason: .videoDeviceNotAvailableDueToSystemPressure), .systemPressure)
        XCTAssertEqual(CaptureInterruption(reason: .videoDeviceNotAvailableInBackground), .notRunnableInBackground)
    }

    /// Every interruption still explains itself; a resume that says nothing is fine, an
    /// interruption that says nothing is not.
    func testEveryInterruptionCarriesAMessage() {
        for interruption in [CaptureInterruption.phoneCall, .takenByAnotherApp, .notRunnableInBackground,
                             .videoDeviceTemporarilyUnavailable, .systemPressure, .sensitiveContentBlocked, .unknown] {
            XCTAssertFalse(interruption.messageKey.isEmpty)
        }
    }
}
