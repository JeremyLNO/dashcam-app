import Foundation

/// What a camera card is allowed to claim.
///
/// « Ready » used to mean *configured*: an input attached, an output attached, a session
/// that says it is running. None of that is a picture. A driver looking at a black preview
/// under three cards reading Ready has been told, three times, something the app does not
/// know — and it happened, twice, on this screen.
///
/// So the card answers to the frames. There are three states and they are not
/// interchangeable: nothing is expected, pictures are arriving, or pictures were expected
/// and are not arriving. The third one is the whole point; it used to be indistinguishable
/// from the second.
enum CameraSignal: Equatable {
    /// The camera is off, or there is none.
    case off
    /// Configured, started, and nothing has come out yet. Ordinary for a second or two at
    /// a cold start, which is why it is its own state rather than a failure.
    case waking
    /// Frames are arriving.
    case live
    /// Frames were arriving, or should have been, and are not.
    case noSignal

    static func assess(isActive: Bool, isRunning: Bool, lastFrame: Date?, startedRunningAt: Date?, now: Date = Date()) -> CameraSignal {
        guard isActive else { return .off }
        guard isRunning, let startedRunningAt else { return .waking }
        switch CaptureWatchdog.assess(isRunning: isRunning, lastFrame: lastFrame, startedRunningAt: startedRunningAt, now: now) {
        case .stalled:
            return .noSignal
        case .healthy:
            return lastFrame == nil ? .waking : .live
        }
    }

    /// What the card says. `recording` is passed in because a live camera during a drive
    /// has something more useful to report than « live ».
    func stateKey(isRecording: Bool) -> String {
        switch self {
        case .off: return "status.off"
        case .waking: return "status.waking"
        case .live: return isRecording ? "status.recording" : "record.ready"
        case .noSignal: return "status.no_signal"
        }
    }

    /// Whether the card should read as a working thing. A camera delivering nothing is not
    /// a working thing, whatever the session says about itself.
    var isHealthy: Bool { self == .live || self == .waking }
}
