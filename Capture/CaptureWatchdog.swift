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
    /// How long a session that *was* delivering may go quiet before it is considered
    /// stuck. Long enough that a thermal hiccup is not mistaken for a freeze; short enough
    /// that a driver setting off does not film a still image for a mile.
    static let stallTolerance: TimeInterval = 4

    /// And how long a session that has delivered **nothing at all** is given.
    ///
    /// The two are not the same question — and the first answer to that was backwards, at
    /// the driver's expense. « A camera that has never produced a frame is misconfigured,
    /// so judge it sooner » sounds right and is wrong: at a cold start the first frame of a
    /// two-camera graph genuinely takes a second or two, and cutting the rope at 1.5 s
    /// rebuilt a session that was about to work. The rebuild costs the wait again, from
    /// zero, and it reported itself as `Ready` throughout.
    ///
    /// The asymmetry is the other way round. **Waiting costs nothing when the frame is on
    /// its way; rebuilding costs a guaranteed delay when it is.** So a session that has
    /// never delivered gets *more* rope than one that has stopped — and when it does run
    /// out, it really is misconfigured.
    static let firstFrameTolerance: TimeInterval = 6

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
        let tolerance = lastFrame == nil ? firstFrameTolerance : stallTolerance
        return now.timeIntervalSince(reference) > tolerance ? .stalled : .healthy
    }
}
