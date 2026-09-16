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
        // The figures go out first and the pictures follow: extracting four frames takes
        // long enough that waiting for it would delay the numbers, which are the part the
        // widget is actually for. The second reload costs nothing when nothing changed.
        Task { await refreshStills(for: snapshot) }
    }

    /// Writes the stills the snapshot names, then sweeps everything it does not.
    private func refreshStills(for snapshot: DashcamSnapshot) async {
        var wrote = false
        for (name, source) in stillSources(for: snapshot) {
            if await StillStore.write(named: name, from: source.url, at: source.seconds) { wrote = true }
        }
        StillStore.sweep(keeping: [snapshot.lastDriveStill].compactMap { $0 } + snapshot.protectedStills)
        if wrote { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Where each still comes from: a file on disk and a moment inside it.
    private func stillSources(for snapshot: DashcamSnapshot) -> [(String, (url: URL, seconds: TimeInterval))] {
        let sessions = index.allSessions()
        var sources: [(String, (url: URL, seconds: TimeInterval))] = []

        if let name = snapshot.lastDriveStill,
           let session = sessions.first(where: { StillStore.name(for: $0.id) == name }),
           let segment = session.rearSegments.first {
            // A few seconds in rather than the very first frame: a drive begins with the
            // camera still settling, and the first frame of a dashcam is usually a garage.
            sources.append((name, (StorageLocations.absoluteURL(forRelativePath: segment.relativePath), 4)))
        }

        for session in sessions {
            for event in session.activeEvents {
                let name = StillStore.name(for: session.id, event: event.id)
                guard snapshot.protectedStills.contains(name) else { continue }
                // The frame at the moment itself, measured from the segment that holds it.
                let offset = event.triggerDate.timeIntervalSince(session.startedAt)
                guard let segment = session.rearSegments.last(where: { $0.startDate <= event.triggerDate })
                        ?? session.rearSegments.first else { continue }
                let within = max(0, event.triggerDate.timeIntervalSince(segment.startDate))
                _ = offset
                sources.append((name, (StorageLocations.absoluteURL(forRelativePath: segment.relativePath), within)))
            }
        }
        return sources
    }

    func makeSnapshot(now: Date = Date()) -> DashcamSnapshot {
        let sessions = index.allSessions()
        // The last *finished* drive: one still being written has no figures worth showing,
        // and showing it would make a drive in progress look like a drive that ended.
        let lastDrive = sessions
            .filter { $0.endedAt != nil }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }

        let protectedEvents = sessions.flatMap(\.activeEvents).sorted { $0.triggerDate > $1.triggerDate }
        let oldestProtected = protectedEvents.map(\.triggerDate).min()
        let snapshotStorage = storage.snapshot

        return DashcamSnapshot(
            lastDriveEndedAt: lastDrive?.endedAt,
            state: L10n.t("widget.state.ready"),
            stateStale: L10n.t(lastDrive == nil ? "widget.state.never" : "widget.state.stale"),
            lastDriveDuration: lastDrive.map { Format.duration($0.duration) } ?? "",
            lastDriveClips: lastDrive.map(clips(of:)) ?? L10n.t("widget.no_drive"),
            storageFree: L10n.t("widget.free", Format.bytes(snapshotStorage.freeBytes)),
            storageUsedFraction: usedFraction(snapshotStorage),
            autonomy: L10n.t("widget.autonomy", Int(hoursLeft(snapshotStorage).rounded())),
            protectedWaiting: protectedLine(count: protectedEvents.count, oldest: oldestProtected),
            protectedShort: protectedEvents.isEmpty ? nil : protectedLabel(count: protectedEvents.count),
            lastDriveStill: lastDrive.map { StillStore.name(for: $0.id) },
            protectedStills: protectedEvents.prefix(3).map { StillStore.name(for: $0.sessionID, event: $0.id) },
            writtenAt: now
        )
    }

    /// « 12 clips enregistrés ».
    ///
    /// The clip count is here on purpose and it is the whole reason this line is worth a
    /// widget: it is the only figure that requires files to exist. A drive that declared
    /// itself and recorded nothing reads « 0 clips » instead of looking like every other
    /// drive in the list.
    private func clips(of session: DriveSession) -> String {
        let count = session.segmentCount
        return count == 1 ? L10n.t("widget.clips.one") : L10n.t("widget.clips.other", count)
    }

    private func usedFraction(_ snapshot: StorageSnapshot) -> Double {
        let total = Double(snapshot.totalBytes)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - Double(snapshot.freeBytes) / total))
    }

    private func hoursLeft(_ snapshot: StorageSnapshot) -> Double {
        DashcamStatusRules.hoursRemaining(
            freeBytes: snapshot.freeBytes,
            gigabytesPerHour: settingsStore.settings.quality.gigabytesPerHour
        )
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
