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
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-tolerance - 0.1), now: now),
            .stalled
        )
    }

    /// Tested on the boundary itself, not comfortably past it.
    func testTheToleranceIsExclusiveAtItsBoundary() {
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-tolerance), now: now),
            .healthy,
            "exactly at the tolerance is still healthy"
        )
        XCTAssertEqual(
            CaptureWatchdog.assess(isRunning: true, lastFrame: nil, startedRunningAt: now.addingTimeInterval(-tolerance - 0.01), now: now),
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
}
