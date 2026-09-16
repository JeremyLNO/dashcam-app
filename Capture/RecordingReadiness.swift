import Foundation

/// Whether the cameras can actually deliver pictures **right now** — asked before a drive
/// is created, rather than discovered afterwards from an empty folder.
///
/// The failure this exists for was reported from the car: START pressed on the CarPlay
/// screen with the iPhone locked. iOS suspends camera capture for any app that is not in
/// the foreground **on the phone itself**, and a CarPlay scene does not count as that.
/// Everything else went on working — the session row was created, the writers opened, the
/// duration ticked on the car's screen, the template said RECORDING — and not one frame
/// ever arrived. The driver was told a drive was being recorded while nothing was written
/// at all, which for a dashcam is the worst failure available: it is discovered after the
/// accident, by someone looking for footage that does not exist.
///
/// There is no way to record with the phone locked; that is an iOS rule, not a setting. So
/// the whole fix is to stop claiming otherwise.
enum RecordingReadiness: Equatable {
    case ready
    /// The pipeline is still coming up. **Not** a refusal: a camera that is not ready yet
    /// and a camera that will never be ready are opposite facts, and telling them apart is
    /// the difference between waiting half a second and showing « the cameras are not
    /// running » over two live previews. Tapping the widget did exactly that.
    case starting
    /// Cannot record, with the reason in terms the driver can act on.
    case blocked(titleKey: String, messageKey: String)

    var isReady: Bool { self == .ready }

    /// The message, for a surface that has room for one line and no alert.
    var messageKey: String? {
        switch self {
        case .ready, .starting: return nil
        case .blocked(_, let messageKey): return messageKey
        }
    }

    static func assess(_ status: CaptureStatus) -> RecordingReadiness {
        // Nothing has been built yet — it is about to be. Everything below would read that
        // as a failure, and at launch it is simply « not yet ».
        guard status.hasBeenConfigured else { return .starting }

        if status.mode == .unavailable {
            return .blocked(
                titleKey: "alert.camera_unavailable.title",
                messageKey: status.unavailability?.messageKey ?? "capture.error.no_camera"
            )
        }
        // An interruption is the locked-phone case, and also the thermal cut-off. Both mean
        // the same thing here: no frames are coming. The microphone being taken by another
        // app does **not** — the cameras keep running, and a dashcam films the road. A
        // drive refused because a map spoke a turn is a drive that was not filmed.
        if let interruption = status.interruption, interruption.affectsVideo {
            return .blocked(titleKey: "alert.camera_unavailable.title", messageKey: interruption.messageKey)
        }
        // Configured but not started: the session is stopped while the library is on
        // screen, and starts again a moment after the drive is asked for. Also « not yet ».
        guard status.isRunning else { return .starting }
        return .ready
    }

    /// The second belt, and the one that does not depend on iOS telling us the truth: a
    /// drive that has been running for a moment and has never received a frame is not
    /// recording, whatever the session claims about itself.
    ///
    /// Deliberately compared against the drive's own start rather than against `now`: a
    /// frame from *before* the drive began proves nothing about the drive.
    static func hasReceivedFootage(startedAt: Date, lastFrame: Date?) -> Bool {
        guard let lastFrame else { return false }
        return lastFrame >= startedAt
    }

    /// How long to wait for that first frame. The preview is already live when Start is
    /// pressed, so a frame is due within milliseconds; this is generous by two orders of
    /// magnitude and still bounds the lie to a few seconds.
    static let firstFrameGrace: TimeInterval = CaptureWatchdog.stallTolerance

    /// How long a drive asked for at launch waits for the cameras before giving up.
    ///
    /// Generous, because the cost of waiting is a moment and the cost of refusing is a
    /// drive that was not filmed — and because the thing being waited for is a two-camera
    /// graph built from cold, which is the slowest thing this app does.
    static let startupGrace: TimeInterval = 8
}
