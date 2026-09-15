import CoreLocation
import Foundation

/// Whether the app may still ask for **Always**, and whether it is worth offering.
///
/// iOS forbids asking for Always first: the prompt only appears for an app that already
/// holds *When In Use*, and it appears **once**. A second call does nothing at all — no
/// prompt, no error, no return value — so an app that re-asks looks broken to its author
/// and does nothing to its user. That single shot is why this is a decision rather than a
/// call site.
///
/// What Always buys a dashcam is narrow and worth stating plainly: the drive itself needs
/// the app on screen — iOS suspends camera capture otherwise — so Always changes nothing
/// about recording. It changes what happens *around* it: the position keeps being delivered
/// when the phone's own screen is not the one in front of the driver, which is exactly the
/// case when the car's screen is.
enum LocationUpgrade: Equatable {
    /// The prompt can be raised, and is worth raising.
    case ask
    /// Nothing to do: already granted, refused, never granted the first step, or already
    /// asked once.
    case none

    static func decide(
        authorization: CLAuthorizationStatus,
        wantsLocation: Bool,
        hasAlreadyAsked: Bool
    ) -> LocationUpgrade {
        guard wantsLocation, !hasAlreadyAsked else { return .none }
        // Only from When In Use. `.notDetermined` is the first prompt's business, and
        // asking for Always there raises nothing — a silence easily mistaken for a refusal.
        return authorization == .authorizedWhenInUse ? .ask : .none
    }

    /// Whether the driver should be *offered* the upgrade at all. Same rule minus the
    /// one-shot memory: a row that vanishes the instant it is tapped, before the system
    /// prompt has even been answered, reads as a bug.
    static func isOfferable(authorization: CLAuthorizationStatus, wantsLocation: Bool) -> Bool {
        wantsLocation && authorization == .authorizedWhenInUse
    }
}
