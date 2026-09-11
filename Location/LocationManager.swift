import CoreLocation
import Foundation

/// GPS, used for metadata only.
///
/// This app provides no navigation: there is no map, no route, no geocoding and no
/// destination. Locations are sampled while recording, stored beside the footage, and
/// used for one thing — optionally stamping an exported file. Nothing leaves the device.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var latest: CLLocation?
    @Published private(set) var isUpdating = false

    /// Called for each accepted fix while a drive is recording.
    var onSample: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    /// One sample every two seconds is plenty to reconstruct speed over a drive, and
    /// keeps a 3-hour session under six thousand rows.
    private let minimumSampleInterval: TimeInterval = 2
    private var lastSampleDate: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Triggers the system prompt. Called only after the in-app explanation screen.
    func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        isUpdating = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        isUpdating = false
        lastSampleDate = nil
    }

    /// Speed in km/h for the HUD, nil when the fix carries no usable speed.
    var currentSpeedKilometresPerHour: Double? {
        guard let speed = latest?.speed, speed >= 0 else { return nil }
        return speed * 3.6
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorization = status
            // The user can grant permission mid-drive; pick up where we left off.
            if status == .authorizedWhenInUse || status == .authorizedAlways, self?.isUpdating == true {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latest = location

            // Reject junk fixes rather than storing a position that is a kilometre wide.
            guard location.horizontalAccuracy > 0, location.horizontalAccuracy < 100 else { return }
            let now = Date()
            if let last = self.lastSampleDate, now.timeIntervalSince(last) < self.minimumSampleInterval { return }
            self.lastSampleDate = now
            self.onSample?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A GPS failure must never stop the cameras. Log and carry on.
        Log.location.error("Location failure: \(error.localizedDescription, privacy: .public)")
    }
}
