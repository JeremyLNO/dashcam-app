import Foundation

/// What the home screen knows about the dashcam.
///
/// Written by the app, read by the widget extension, and carrying **already-formatted
/// text** rather than raw figures. That is deliberate: the app has a language of its own —
/// a driver can set Dashcam to French on an English phone — and an extension resolving its
/// own strings would quietly disagree with the app that produced them. One formatter, above
/// both surfaces, is the only arrangement that cannot drift.
///
/// The one thing *not* pre-formatted is the date of the last drive, because that is the
/// only value that goes stale on its own. It travels as a `Date` so the widget can render
/// it relative and let iOS keep it true without the app ever running again.
struct DashcamSnapshot: Codable, Equatable, Sendable {
    /// When the last finished drive ended. `nil` when nothing has ever been recorded.
    var lastDriveEndedAt: Date?
    /// « DERNIER TRAJET », or « JAMAIS ENREGISTRÉ ». Sits where the app's own name would
    /// otherwise be repeated — the widget is already labelled on the home screen.
    var headline: String
    /// « 34 min · 12 clips ». The clip count is there on purpose: it is the only figure
    /// that requires files to exist, so a drive that recorded nothing reads as « 0 clips »
    /// instead of looking like every other drive.
    var lastDriveSummary: String
    /// « 86 Go · ≈ 11 h ».
    var autonomy: String
    /// « 1 moment protégé · 14 sept. », or nil when there is nothing waiting.
    var protectedWaiting: String?
    /// The same thing without its date, for the small widget — where the long form is cut
    /// mid-word, which reads as a bug rather than as a shortage of room.
    var protectedShort: String?
    /// When the app last wrote this. A widget showing figures from three weeks ago is the
    /// same silent lie as a player that shows black: the age has to be legible.
    var writtenAt: Date

    static let empty = DashcamSnapshot(
        lastDriveEndedAt: nil, headline: "", lastDriveSummary: "", autonomy: "",
        protectedWaiting: nil, protectedShort: nil, writtenAt: .distantPast
    )
}

/// The rules behind the widget, kept apart from the drawing so they can be checked.
enum DashcamStatusRules {
    /// How long a dashcam may go unused before the widget says so rather than showing a
    /// stale success.
    ///
    /// A week: long enough to cover a car left at the station Monday to Friday, short
    /// enough that « it has not recorded since the 2nd » reaches someone who believes
    /// their dashcam is filming every day. The whole value of this widget is in the case
    /// where the answer is no.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    static func isStale(lastDriveEndedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastDriveEndedAt else { return true }
        return now.timeIntervalSince(lastDriveEndedAt) > staleAfter
    }

    /// How many hours of footage the free space still holds, at the quality in use.
    static func hoursRemaining(freeBytes: Int64, gigabytesPerHour: Double) -> Double {
        guard gigabytesPerHour > 0, freeBytes > 0 else { return 0 }
        let gigabytes = Double(freeBytes) / 1_000_000_000
        return gigabytes / gigabytesPerHour
    }
}

/// Where the snapshot lives: a file in the container both binaries can reach.
///
/// A file rather than `UserDefaults`, for one reason — a half-written defaults suite comes
/// back as a *partly* populated dictionary, while a half-written JSON file fails to decode
/// and the widget falls back to saying it does not know. Between a wrong figure and an
/// admitted absence, a dashcam owes the second.
enum DashcamSnapshotStore {
    /// Must match the `com.apple.security.application-groups` entitlement on **both** the
    /// app and the extension. Getting it wrong does not fail to build and does not raise:
    /// `containerURL` simply returns nil and the widget stays empty forever.
    static let appGroup = "group.company.lno.dashcam"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    /// Returns whether it landed. The caller logs — this file is compiled into the widget
    /// extension too, where the app's logging category does not exist.
    @discardableResult
    static func write(_ snapshot: DashcamSnapshot) -> Bool {
        guard let fileURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return false }
        // Atomic: a widget that wakes mid-write must read the previous snapshot whole,
        // never half of the new one.
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func read() -> DashcamSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DashcamSnapshot.self, from: data)
    }
}
