import XCTest
@testable import Dashcam

/// What a camera card is allowed to claim.
///
/// Reported from the car, twice: three cards reading **Ready** above a black rectangle.
/// « Ready » meant *configured* — an input attached, an output attached, a session that
/// says it is running — and none of that is a picture. The card now answers to the frames,
/// so a camera producing nothing says so instead of agreeing with the two that work.
final class CameraSignalTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private func signal(isActive: Bool = true, isRunning: Bool = true,
                        lastFrame: Date?, after seconds: TimeInterval) -> CameraSignal {
        CameraSignal.assess(isActive: isActive, isRunning: isRunning, lastFrame: lastFrame,
                            startedRunningAt: startedAt, now: startedAt.addingTimeInterval(seconds))
    }

    func testACameraDeliveringFramesIsLive() {
        XCTAssertEqual(signal(lastFrame: startedAt.addingTimeInterval(9.9), after: 10), .live)
    }

    /// The state that did not exist and had to: a cold start is not a failure, and calling
    /// it one is how a perfectly good session got rebuilt out from under the driver.
    func testACameraThatHasJustStartedIsWakingNotBroken() {
        XCTAssertEqual(signal(lastFrame: nil, after: 1), .waking)
        XCTAssertEqual(signal(lastFrame: nil, after: CaptureWatchdog.firstFrameTolerance - 0.1), .waking)
    }

    /// And the one the whole thing exists for.
    func testACameraThatNeverDeliversSaysSoRatherThanReady() {
        let verdict = signal(lastFrame: nil, after: CaptureWatchdog.firstFrameTolerance + 0.1)
        XCTAssertEqual(verdict, .noSignal)
        XCTAssertFalse(verdict.isHealthy, "a black rectangle must not read as a working camera")
        XCTAssertEqual(verdict.stateKey(isRecording: false), "status.no_signal")
    }

    /// A camera that *was* delivering and stopped is the frozen preview — the same lie,
    /// arrived at from the other side.
    func testAFrozenPreviewIsNotReadyEither() {
        let lastFrame = startedAt.addingTimeInterval(10)
        let verdict = CameraSignal.assess(
            isActive: true, isRunning: true, lastFrame: lastFrame, startedRunningAt: startedAt,
            now: lastFrame.addingTimeInterval(CaptureWatchdog.stallTolerance + 0.1)
        )
        XCTAssertEqual(verdict, .noSignal)
    }

    func testACameraNobodyAskedForIsSimplyOff() {
        XCTAssertEqual(signal(isActive: false, lastFrame: nil, after: 60), .off)
        XCTAssertEqual(signal(isActive: false, lastFrame: nil, after: 60).stateKey(isRecording: false), "status.off")
    }

    /// A session not yet started has nothing to answer for — that is the configuration's
    /// business, not this rule's.
    func testASessionNotYetRunningIsWaking() {
        XCTAssertEqual(signal(isRunning: false, lastFrame: nil, after: 60), .waking)
    }

    /// During a drive, a live camera has something more useful to say than « live ».
    func testALiveCameraDuringADriveSaysRecording() {
        XCTAssertEqual(CameraSignal.live.stateKey(isRecording: true), "status.recording")
        XCTAssertEqual(CameraSignal.live.stateKey(isRecording: false), "record.ready")
    }
}
