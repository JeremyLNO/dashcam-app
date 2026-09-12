import Foundation
import WatchConnectivity

/// The watch half of the link with the phone.
///
/// Deliberately thin: it mirrors what the phone says and posts three commands. No state
/// of its own beyond the last snapshot received, because two devices holding opinions
/// about whether a recording is running is how a remote starts lying.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    @Published private(set) var state = RemoteState.idle
    @Published private(set) var isReachable = false

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func refresh() {
        isReachable = session?.isReachable ?? false
        send(.status)
    }

    func send(_ command: RemoteCommand) {
        guard let session, session.isReachable else {
            isReachable = false
            return
        }
        session.sendMessage(command.payload, replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.apply(reply)
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.isReachable = false }
        })
    }

    private func apply(_ reply: [String: Any]) {
        state = RemoteState(payload: reply) ?? state
        isReachable = true
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.send(.status) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }
}
