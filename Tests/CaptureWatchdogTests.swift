import AVFoundation
import XCTest
@testable import Dashcam

/// When the app decides its own camera has frozen.
///
/// A frozen preview raises no error and posts no interruption: the session reports itself
/// as running and the last frame simply stays there. The only evidence is the absence of
/// frames, so the rule that reads that absence is worth pinning down exactly — including
/// at its boundary, where every threshold is wrong first.
final class CaptureWatchdogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var tolerance: TimeInterval { CaptureWatchdog.stallTolerance }
    /// The two questions have two tolerances: a camera that has *never* delivered is
    /// misconfigured, not slow, and waits less. Each test below uses the one that governs
    /// the case it describes — a threshold tested against the wrong constant proves
    /// nothing at all.
    private var firstFrame: TimeInterval { CaptureWatchdog.firstFrameTolerance }

    func testAStoppedSessionIsNeverStalled() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: false, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-600), now: now),
            .healthy,
            "a session nobody started cannot be stuck"
        )
    }

    func testFramesArrivingMeansHealthy() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: now.addingTimeInterval(-0.1), startedRunningAt: now.addingTimeInterval(-60), now: now),
            .healthy
        )
    }

    /// The failure this exists for: running, and not one frame since it started.
    func testASessionThatNeverDeliveredAFrameIsStalled() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-firstFrame - 0.1), now: now),
            .stalled
        )
    }

    /// Tested on the boundary itself, not comfortably past it.
    func testTheToleranceIsExclusiveAtItsBoundary() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-firstFrame), now: now),
            .healthy,
            "exactly at the tolerance is still healthy"
        )
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-firstFrame - 0.01), now: now),
            .stalled
        )
    }

    /// A camera that delivered frames and then stopped is the other half of the same
    /// failure — the preview freezes on the last picture it managed.
    func testFramesThatStopComingAreStalled() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: now.addingTimeInterval(-tolerance - 1), startedRunningAt: now.addingTimeInterval(-600), now: now),
            .stalled
        )
    }

    /// A session just started has not failed yet: the first frame takes a moment, and
    /// rebuilding the graph for it would loop forever.
    func testAFreshlyStartedSessionIsGivenTime() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-0.5), now: now),
            .healthy
        )
    }

    /// The clamp that keeps the shutter cap inside what a format accepts. Out of bounds is
    /// not a wrong picture — AVFoundation throws.
    func testTheShutterCapIsClampedToWhatTheFormatAccepts() throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw XCTSkip("no camera on this machine, and the clamp needs a real format")
        }
        let clamped = SceneOptimiser.cap(CMTime(value: 1, timescale: 60), within: device.activeFormat)
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(clamped), CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        XCTAssertLessThanOrEqual(CMTimeGetSeconds(clamped), CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
    }

    // MARK: - The first frame is its own question

    /// A session that has never delivered is still judged — just later, once « slow » has
    /// been ruled out. What must not happen is a verdict before a cold start has finished.
    func testASessionThatHasNeverDeliveredIsJudgedOnItsOwnClock() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: started,
                                   now: started.addingTimeInterval(CaptureWatchdog.firstFrameTolerance + 0.1)),
            .stalled
        )
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: started,
                                   now: started.addingTimeInterval(CaptureWatchdog.firstFrameTolerance - 0.1)),
            .healthy,
            "a genuinely slow first frame must not be mistaken for a dead camera"
        )
    }

    /// And a session that has been delivering keeps the longer rope: a thermal hiccup is
    /// not a freeze, and rebuilding the graph mid-drive costs real footage.
    func testASessionThatWasDeliveringKeepsTheLongerTolerance() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let lastFrame = started.addingTimeInterval(10)
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: lastFrame, startedRunningAt: started,
                                   now: lastFrame.addingTimeInterval(CaptureWatchdog.stallTolerance - 0.1)),
            .healthy
        )
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: lastFrame, startedRunningAt: started,
                                   now: lastFrame.addingTimeInterval(CaptureWatchdog.stallTolerance + 0.1)),
            .stalled
        )
    }

    /// The rope runs the other way, and getting it backwards shipped: a first frame that
    /// is merely slow must not be mistaken for a camera that will never produce one, because
    /// waiting costs nothing when the frame is coming and a rebuild costs the whole wait
    /// again when it is.
    func testTheFirstFrameIsGivenMoreRopeThanARunningSession() {
        XCTAssertGreaterThan(
            CaptureWatchdog.firstFrameTolerance, CaptureWatchdog.stallTolerance,
            "a cold multi-camera start takes longer than a running session's hiccup"
        )
        XCTAssertGreaterThanOrEqual(CaptureWatchdog.firstFrameTolerance, 4,
                                    "below this, an ordinary cold start is rebuilt for nothing")
        XCTAssertLessThanOrEqual(CaptureWatchdog.firstFrameTolerance, 10,
                                 "and past this the driver is watching a black rectangle")
    }
}
