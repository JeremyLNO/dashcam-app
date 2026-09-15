import Foundation

/// Which of three screens the car should be showing, and what is on it.
///
/// The whole CarPlay interface answers one question — *what can I do right now?* — and the
/// answer has exactly three forms. Kept as a value, apart from the templates, because
/// `CPGridTemplate` cannot be built on a machine without CarPlay and these are the
/// decisions worth pinning: which screen, which buttons, and above all **which buttons are
/// absent**. START and STOP must never be on screen together; a driver who has to read a
/// button before pressing it is a driver reading instead of driving.
enum CarPlayScreen: Equatable {
    /// Nothing can be recorded. This state takes the whole screen: no counters, no
    /// storage, no camera list — one sentence saying what to do.
    case blocked(detailKey: String)
    /// One dominant button, and the two facts worth a glance.
    case ready(camerasKey: String)
    /// Recording. The elapsed time is the title; stopping and protecting are the screen.
    case recording(isDiscreet: Bool)

    static func decide(isRecording: Bool, readiness: RecordingReadiness, camerasKey: String, isDiscreet: Bool) -> CarPlayScreen {
        // A drive already running outranks a camera the app thinks is unavailable: the
        // footage is being written, and taking Stop away from the driver because of a
        // status flag would be the worse failure.
        if isRecording { return .recording(isDiscreet: isDiscreet) }
        guard readiness.isReady else {
            return .blocked(detailKey: readiness.messageKey ?? "capture.error.no_camera")
        }
        return .ready(camerasKey: camerasKey)
    }

    /// The buttons this screen offers, in order. Named rather than built so the one rule
    /// that matters can be checked without CarPlay.
    enum Action: Equatable {
        case start, stop, protectClip, discreet
    }

    var actions: [Action] {
        switch self {
        // Deliberately none. A button that cannot work is worse than no button: it is
        // pressed, and believed.
        case .blocked: return []
        case .ready: return [.start]
        case .recording: return [.stop, .protectClip, .discreet]
        }
    }
}

/// A confirmation shown for a moment and then gone, without anything to press.
///
/// Asking a driver to acknowledge « saved » is asking them to look at a screen to dismiss
/// news they already wanted. It says itself and it leaves.
enum CarPlayConfirmation: Equatable {
    case clipProtected
    case driveSaved

    var titleKey: String {
        switch self {
        case .clipProtected: return "carplay.confirm.protected"
        case .driveSaved: return "carplay.confirm.saved"
        }
    }

    /// Long enough to be read at a glance, short enough that the screen is back to being
    /// useful before the next junction.
    static let duration: TimeInterval = 2
}
