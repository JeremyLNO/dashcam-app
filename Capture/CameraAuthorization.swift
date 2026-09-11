import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import Photos

/// The permissions the app can ask for, and where in the flow each one belongs.
///
/// Every prompt is preceded by an in-app explanation screen (see `OnboardingView` and
/// the Settings rows) — the system alert is never the first time the user hears about it.
enum AppPermission: String, CaseIterable, Identifiable, Sendable {
    case camera
    case microphone
    case location
    case motion
    case photoLibraryAdd

    var id: String { rawValue }

    var titleKey: String { "permission.\(rawValue).title" }
    var explanationKey: String { "permission.\(rawValue).explanation" }
}

enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
    /// The platform gives no way to query this ahead of time (Core Motion activity).
    case unknown
}

/// Thin, testable wrapper over the five permission APIs. No UI, no side effects beyond
/// the system prompt itself.
@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var statuses: [AppPermission: PermissionStatus] = [:]

    /// Supplied by `AppEnvironment`. Creating a second `CLLocationManager` just to read a
    /// status costs measurable launch time, so the one `LocationManager` already owns is
    /// the single source.
    var locationStatusProvider: () -> CLAuthorizationStatus = { .notDetermined }

    init() {}

    func refresh() {
        statuses[.camera] = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        statuses[.microphone] = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        statuses[.location] = Self.map(locationStatusProvider())
        statuses[.motion] = Self.motionStatus()
        statuses[.photoLibraryAdd] = Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func status(for permission: AppPermission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    @discardableResult
    func request(_ permission: AppPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .location:
            // CoreLocation's prompt is driven by the running manager, not by a one-shot
            // call — LocationManager owns it so there is exactly one CLLocationManager.
            break
        case .motion:
            // Core Motion prompts implicitly on first query; MotionManager triggers it.
            break
        case .photoLibraryAdd:
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        refresh()
        return status(for: permission)
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func motionStatus() -> PermissionStatus {
        guard CMMotionActivityManager.isActivityAvailable() else { return .restricted }
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}
