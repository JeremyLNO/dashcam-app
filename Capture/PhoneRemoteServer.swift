import Combine
import Foundation
import WatchConnectivity

/// The phone half of the wrist remote.
///
/// Answers the three commands the watch can send, and replies with the state that made
/// the answer true — the watch never has to guess whether its tap landed.
///
/// Start is the one command that can legitimately fail: iOS suspends camera capture
/// outside the foreground, so a phone whose app is in the background cannot begin
/// filming. `WCSession` will happily wake the app to deliver the message, which is
/// exactly the trap — the reply simply reports the recording state as it really is, and
/// the watch shows that rather than a success it did not get.
@MainActor
final class PhoneRemoteServer: NSObject, ObservableObject {
    private let recording: RecordingManager
    private let index: SessionIndex
    private var cancellables = Set<AnyCancellable>()

    init(recording: RecordingManager, index: SessionIndex) {
        self.recording = recording
        self.index = index
        super.init()

        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        // The watch is told when the state changes rather than polling for it, so the
        // dot on the wrist matches the button that was just pressed on the phone.
        recording.$isRecording
            .removeDuplicates()
            .sink { [weak self] _ in self?.pushState() }
            .store(in: &cancellables)
    }

    private var currentState: RemoteState {
        RemoteState(
            isRecording: recording.isRecording,
            elapsed: recording.elapsed,
            protectedCount: recording.currentSessionID.map { index.activeEvents(forSession: $0).count } ?? 0
        )
    }

    private func pushState() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(currentState.payload, replyHandler: nil, errorHandler: nil)
    }

    fileprivate func handle(_ command: RemoteCommand) async -> [String: Any] {
        switch command {
        case .status:
            break
        case .start:
            if !recording.isRecording { await recording.start() }
        case .stop:
            if recording.isRecording { await recording.stop() }
        case .protect:
            recording.protectNow(origin: .manual)
        }
        return currentState.payload
    }
}

extension PhoneRemoteServer: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = RemoteCommand(payload: message) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            replyHandler(await self.handle(command))
        }
    }
}
