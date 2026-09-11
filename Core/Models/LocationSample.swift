import Foundation
import SwiftData

/// A single GPS fix attached to a drive.
///
/// Used for two things only: stamping an exported file on request, and showing speed in
/// the library. It is never turned into a route, a map or a navigation instruction.
@Model
final class LocationSample {
    // (`#Index` would help the library queries here, but it needs iOS 18 and the
    //  deployment floor is 17 so older iPhones can still run rear-only.)

    var sessionID: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    /// Metres per second. Negative means "device could not determine speed".
    var speed: Double
    var course: Double
    var altitude: Double
    var horizontalAccuracy: Double

    var session: DriveSession?

    init(
        sessionID: UUID,
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        speed: Double,
        course: Double,
        altitude: Double,
        horizontalAccuracy: Double
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.course = course
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    var speedKilometresPerHour: Double? {
        speed < 0 ? nil : speed * 3.6
    }
}
