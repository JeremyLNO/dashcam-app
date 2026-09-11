import Foundation
import UIKit

/// What the app should do about heat right now.
enum ThermalAction: Equatable, Sendable {
    case none
    /// Drop one quality tier.
    case reduceQuality
    /// Quality is already at the floor: shed the cabin camera and keep the road.
    case dropFrontCamera
    /// Nothing left to give.
    case stopRecording

    var messageKey: String? {
        switch self {
        case .none: return nil
        case .reduceQuality: return "thermal.reduced_quality"
        case .dropFrontCamera: return "thermal.front_dropped"
        case .stopRecording: return "thermal.stopped"
        }
    }
}

/// Watches thermal state and the multi-cam hardware budget, and says what to give up.
///
/// The priority order is fixed and non-negotiable: the road camera is the evidence, so
/// resolution goes first, then the cabin camera, and stopping is a last resort. The app
/// never simply lets the device cook until iOS kills it.
@MainActor
final class ThermalManager: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var currentAction: ThermalAction = .none
    /// Quality currently in force, which may be below what the user selected.
    @Published private(set) var effectiveQuality: VideoQuality = .standard
    @Published private(set) var isFrontCameraShed = false

    /// Raised when the action changes, so the recorder can apply it.
    var onActionChanged: ((ThermalAction) -> Void)?

    private var observer: NSObjectProtocol?
    private var userQuality: VideoQuality = .standard
    /// Once shed, features come back only after a cool-down at nominal — otherwise the
    /// app oscillates between quality tiers every few seconds.
    private var lastEscalation: Date?
    private let recoveryDelay: TimeInterval = 120

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor in self?.handle(state: state) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func begin(userQuality: VideoQuality) {
        self.userQuality = userQuality
        effectiveQuality = userQuality
        isFrontCameraShed = false
        currentAction = .none
        lastEscalation = nil
        handle(state: ProcessInfo.processInfo.thermalState)
    }

    /// Called with the live multi-cam costs. A `systemPressureCost` at or above 1.0 means
    /// the session is about to be shut down by the system, so it counts as serious as a
    /// `.serious` thermal state.
    func update(hardwareCost: Float, systemPressureCost: Float) {
        guard systemPressureCost >= 1.0 else { return }
        escalate(to: .serious)
    }

    private func handle(state: ProcessInfo.ThermalState) {
        thermalState = state
        switch state {
        case .nominal, .fair:
            relaxIfPossible()
        case .serious:
            escalate(to: .serious)
        case .critical:
            escalate(to: .critical)
        @unknown default:
            break
        }
    }

    private func escalate(to state: ProcessInfo.ThermalState) {
        let action: ThermalAction
        if state == .critical && isFrontCameraShed && effectiveQuality == .eco {
            action = .stopRecording
        } else if let degraded = effectiveQuality.degraded {
            effectiveQuality = degraded
            action = .reduceQuality
        } else if !isFrontCameraShed {
            isFrontCameraShed = true
            action = .dropFrontCamera
        } else {
            action = .stopRecording
        }
        lastEscalation = Date()
        guard action != currentAction || action == .reduceQuality else { return }
        currentAction = action
        onActionChanged?(action)
    }

    private func relaxIfPossible() {
        guard currentAction != .none else { return }
        guard let last = lastEscalation, Date().timeIntervalSince(last) > recoveryDelay else { return }
        effectiveQuality = userQuality
        isFrontCameraShed = false
        currentAction = .none
        lastEscalation = nil
        onActionChanged?(.none)
    }
}
