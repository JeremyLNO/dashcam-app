import CoreLocation
import Foundation

/// Turns a stream of GPS fixes into a distance travelled.
///
/// Its whole job is rejecting the legs that are not real. A stationary phone's fix
/// wanders by a few metres every second; summed over a red light that invents hundreds of
/// metres, and over a drive it can invent kilometres. A jump of a kilometre between two
/// consecutive fixes is the opposite problem — a tunnel exit or a cold start — and adding
/// it would be just as wrong.
///
/// Pulled out of `RecordingManager` so both rules can be tested without a device.
struct DistanceAccumulator {
    /// Below this, the leg is indistinguishable from GPS noise.
    static let minimumLegMetres: CLLocationDistance = 5
    /// Above this, it is a re-acquisition rather than movement.
    static let maximumLegMetres: CLLocationDistance = 1000
    /// A fix this imprecise cannot support a 5 m decision.
    static let maximumAccuracyMetres: CLLocationAccuracy = 50

    private(set) var totalMetres: CLLocationDistance = 0
    private var previous: CLLocation?

    mutating func reset() {
        totalMetres = 0
        previous = nil
    }

    /// Adds the leg ending at `fix`, and returns how many metres it contributed.
    @discardableResult
    mutating func add(_ fix: CLLocation) -> CLLocationDistance {
        guard fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= Self.maximumAccuracyMetres else {
            // Keep the previous anchor: replacing it with a bad fix would poison the next
            // leg too.
            return 0
        }
        defer { previous = fix }
        guard let previous else { return 0 }

        let metres = fix.distance(from: previous)
        guard metres >= Self.minimumLegMetres, metres <= Self.maximumLegMetres else { return 0 }
        totalMetres += metres
        return metres
    }
}
