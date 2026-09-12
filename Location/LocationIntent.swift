import CoreLocation
import Foundation

/// What the app should do about location right now, given what the driver asked for and
/// what iOS currently allows.
///
/// It exists because the two are easy to confuse, and the confusion is invisible: a
/// driver who taps **Allow Once** has location working for that session and gone the
/// next, since iOS returns the authorisation to *not determined* when the app is
/// relaunched. The setting still says they want position; only the permission expired.
/// Showing "Off" there is technically true and practically a lie — the app simply never
/// asked again.
///
/// Pure arithmetic on three inputs, so the rule can be tested rather than observed on a
/// phone a day later.
enum LocationIntent: Equatable {
    /// Ask iOS for permission: the driver wants position and nobody has been asked yet —
    /// or the last answer was "once" and has since lapsed.
    case request
    /// Permission is granted and wanted: keep a fix warm so the first seconds of a drive
    /// are not recorded without one.
    case start
    /// Stop the updates: either the driver turned the setting off, or the app is leaving
    /// the foreground with no recording to serve.
    case stop
    /// Nothing to do — most of the time.
    case none

    static func decide(
        wantsLocation: Bool,
        authorization: CLAuthorizationStatus,
        isRecording: Bool,
        isUpdating: Bool,
        isForeground: Bool
    ) -> LocationIntent {
        guard wantsLocation else { return isUpdating ? .stop : .none }

        switch authorization {
        case .notDetermined:
            // Only worth asking while the app is on screen: a prompt fired from the
            // background is a prompt nobody sees and an answer nobody gives.
            return isForeground ? .request : .none
        case .denied, .restricted:
            // Nothing the app can do; the recording screen offers the way to Settings.
            return isUpdating ? .stop : .none
        default:
            if isRecording { return isUpdating ? .none : .start }
            if !isForeground { return isUpdating ? .stop : .none }
            return isUpdating ? .none : .start
        }
    }
}
