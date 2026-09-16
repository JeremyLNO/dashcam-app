import Foundation
import WidgetKit

/// Builds the widget's snapshot and hands it over.
///
/// Every line it writes is already localised and already formatted, because the app has a
/// language of its own — a driver can run Dashcam in French on an English phone — and an
/// extension resolving its own strings would quietly disagree with the app that fed it.
///
/// It is called **on events**, never on a timer: a drive ending, a moment protected, a
/// retention sweep. A widget refreshed on a schedule shows figures from whenever the
/// schedule last fired, which is the same silent lie as a player showing black — it looks
/// exactly like a widget that is up to date.
@MainActor
struct WidgetFeeder {
    let index: SessionIndex
    let storage: StorageManager
    let settingsStore: SettingsStore

    func refresh() {
        let snapshot = makeSnapshot()
        guard DashcamSnapshotStore.write(snapshot) else {
            Log.storage.error("Widget snapshot not written — no app group container")
            return
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func makeSnapshot(now: Date = Date()) -> DashcamSnapshot {
        let sessions = index.allSessions()
        // The last *finished* drive: one still being written has no figures worth showing,
        // and showing it would make a drive in progress look like a drive that ended.
        let lastDrive = sessions
            .filter { $0.endedAt != nil }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }

        let protectedEvents = sessions.flatMap(\.activeEvents)
        let oldestProtected = protectedEvents.map(\.triggerDate).min()

        let protectedCount = protectedEvents.count
        return DashcamSnapshot(
            lastDriveEndedAt: lastDrive?.endedAt,
            headline: L10n.t(lastDrive == nil ? "widget.headline.never" : "widget.headline.last"),
            lastDriveSummary: lastDrive.map(summary(of:)) ?? L10n.t("widget.no_drive"),
            autonomy: autonomy(),
            protectedWaiting: protectedLine(count: protectedCount, oldest: oldestProtected),
            protectedShort: protectedCount > 0 ? protectedLabel(count: protectedCount) : nil,
            writtenAt: now
        )
    }

    /// « 34 min · 12 clips ».
    ///
    /// The clip count is here on purpose and it is the whole reason this line is worth a
    /// widget: it is the only figure that requires files to exist. A drive that declared
    /// itself and recorded nothing reads « 0 clips » instead of looking like every other
    /// drive in the list.
    private func summary(of session: DriveSession) -> String {
        let clips = session.segmentCount
        let clipsText = clips == 1 ? L10n.t("widget.clips.one") : L10n.t("widget.clips.other", clips)
        return "\(Format.duration(session.duration)) · \(clipsText)"
    }

    /// « 86 Go · ≈ 11 h ».
    private func autonomy() -> String {
        let free = storage.snapshot.freeBytes
        let hours = DashcamStatusRules.hoursRemaining(
            freeBytes: free, gigabytesPerHour: settingsStore.settings.quality.gigabytesPerHour
        )
        return "\(Format.bytes(free)) · \(L10n.t("widget.autonomy", Int(hours.rounded())))"
    }

    /// A protected moment is evidence with a deadline: the retention sweep will not touch
    /// it, which is exactly why it is forgotten. Nothing else in the app ever brings it up
    /// again.
    private func protectedLine(count: Int, oldest: Date?) -> String? {
        guard count > 0, let oldest else { return nil }
        return "\(protectedLabel(count: count)) · \(Format.date(oldest))"
    }

    private func protectedLabel(count: Int) -> String {
        count == 1 ? L10n.t("widget.protected.one") : L10n.t("widget.protected.other", count)
    }
}
