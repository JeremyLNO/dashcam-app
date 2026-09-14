import Foundation

/// Decides when a running capture session has stopped producing pictures.
///
/// A frozen preview is the one camera failure that looks like nothing at all: the session
/// says it is running, no error is raised, no interruption is posted — and the last frame
/// stays on screen. A driver only finds out afterwards, which for a dashcam is the whole
/// loss.
///
/// So the app stops trusting `isRunning` and watches the frames instead. The rule is
/// deliberately a pure function of three facts, because "should we rebuild the camera" is
/// exactly the kind of decision that must be testable rather than observed on a phone.
enum CaptureWatchdog {
    /// How long a running session may go without delivering a frame before it is
    /// considered stuck. Long enough that a thermal hiccup or a slow first frame after
    /// launch is not mistaken for a freeze; short enough that a driver setting off does
    /// not film a still image for a mile.
    static let stallTolerance: TimeInterval = 4

    enum Verdict: Equatable {
        /// Frames are arriving, or nothing is expected yet.
        case healthy
        /// The session claims to run and has delivered nothing for too long.
        case stalled
    }

    static func assess(
        isRunning: Bool,
        lastFrame: Date?,
        startedRunningAt: Date?,
        now: Date = Date()
    ) -> Verdict {
        guard isRunning, let startedRunningAt else { return .healthy }

        // Before the first frame, the clock starts at the moment the session started: a
        // camera that never delivers anything is exactly the failure being looked for,
        // and waiting for a frame that will not come would wait forever.
        let reference = lastFrame ?? startedRunningAt
        return now.timeIntervalSince(reference) > stallTolerance ? .stalled : .healthy
    }
}
