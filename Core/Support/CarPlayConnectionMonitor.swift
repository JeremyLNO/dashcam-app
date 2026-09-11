import AVFoundation
import Combine
import Foundation

/// Notices when the phone is plugged into a car.
///
/// What this can and cannot do is worth stating plainly, because the difference decides
/// how the feature has to be built:
///
/// * **It can tell you CarPlay connected while the app is running.** The audio route
///   changes, `AVAudioSession` posts a notification, and the port type says `carAudio`.
/// * **It cannot launch the app.** iOS gives no app the ability to start itself, and there
///   is no "launch on CarPlay connect" entitlement. An app that is not running learns
///   nothing.
///
/// So the app covers the first case itself, and the second is covered by a Shortcuts
/// personal automation the driver sets up once — "When CarPlay connects, run Start
/// Recording" — which is why `StartRecordingIntent` exists.
@MainActor
final class CarPlayConnectionMonitor: ObservableObject {
    @Published private(set) var isConnected = false

    /// Fires on the transition into a car, never on the steady state.
    var onConnected: (() -> Void)?

    private var observer: NSObjectProtocol?

    init() {
        isConnected = Self.isCarPlay(route: AVAudioSession.sharedInstance().currentRoute)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleRouteChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func handleRouteChange() {
        let connected = Self.isCarPlay(route: AVAudioSession.sharedInstance().currentRoute)
        defer { isConnected = connected }
        guard connected, !isConnected else { return }
        Log.carplay.info("CarPlay connected")
        onConnected?()
    }

    nonisolated static func isCarPlay(route: AVAudioSessionRouteDescription) -> Bool {
        isCarPlay(portTypes: route.outputs.map(\.portType))
    }

    /// Split out from the route so the rule can be tested without conjuring an
    /// `AVAudioSessionRouteDescription`, which cannot be constructed outside CoreAudio.
    nonisolated static func isCarPlay(portTypes: [AVAudioSession.Port]) -> Bool {
        portTypes.contains(.carAudio)
    }

    /// Whether a connection should actually start a recording.
    ///
    /// Pure on purpose: this is the decision the feature lives or dies by, and it should
    /// be testable without a car.
    nonisolated static func shouldAutoStart(isEnabled: Bool, isAlreadyRecording: Bool, isCameraReady: Bool) -> Bool {
        isEnabled && !isAlreadyRecording && isCameraReady
    }
}
