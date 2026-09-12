import Foundation

/// The three things a wrist can ask of the phone, and what it gets told back.
///
/// Compiled into both the watch app and the iPhone app: one definition, so a rename
/// cannot leave the two halves speaking different dialects of the same protocol.
enum RemoteCommand: String {
    case status
    case start
    case stop
    case protect

    var payload: [String: Any] { ["command": rawValue] }

    init?(payload: [String: Any]) {
        guard let raw = payload["command"] as? String, let command = RemoteCommand(rawValue: raw) else { return nil }
        self = command
    }
}

/// What the phone reports back. Deliberately small — a remote shows a state, it does not
/// hold one.
struct RemoteState: Equatable {
    var isRecording: Bool
    var elapsed: TimeInterval
    var protectedCount: Int

    static let idle = RemoteState(isRecording: false, elapsed: 0, protectedCount: 0)

    var elapsedText: String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    var payload: [String: Any] {
        ["isRecording": isRecording, "elapsed": elapsed, "protectedCount": protectedCount]
    }

    init(isRecording: Bool, elapsed: TimeInterval, protectedCount: Int) {
        self.isRecording = isRecording
        self.elapsed = elapsed
        self.protectedCount = protectedCount
    }

    init?(payload: [String: Any]) {
        guard let isRecording = payload["isRecording"] as? Bool else { return nil }
        self.isRecording = isRecording
        self.elapsed = payload["elapsed"] as? TimeInterval ?? 0
        self.protectedCount = payload["protectedCount"] as? Int ?? 0
    }
}
