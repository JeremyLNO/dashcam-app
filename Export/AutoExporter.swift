import Foundation
import Photos

/// Writes protected footage out of the app by itself, as soon as a drive ends.
///
/// The reason for it is the situation the app exists for: someone has just been hit, is
/// shaken, and is not going to think about exporting anything. The clip that matters is
/// already protected from the cleanup — but it still lives inside an app's private
/// container, where it is one uninstall away from gone. This puts a copy somewhere the
/// driver already knows how to find.
///
/// Three rules govern it, and each of them is a refusal to surprise anyone:
///
/// * **It is off by default.** Writing to someone's photo library without being asked is
///   not a feature.
/// * **It exports the event window, not the drive.** Ten seconds either side of an impact
///   is what an insurer looks at; a two-hour drive in the camera roll is a punishment.
/// * **It never exports twice.** Each event carries the date it was exported, so a second
///   drive, a relaunch or a crash recovery cannot fill the library with duplicates.
@MainActor
final class AutoExporter: ObservableObject {
    /// What happened on the last run, for the settings screen to show.
    @Published private(set) var lastOutcome: Outcome?

    enum Outcome: Equatable {
        case exported(count: Int)
        case skippedNoSubscription
        case skippedNoPermission
        case failed(String)
    }

    private let index: SessionIndex
    private let exporter: ExportManager
    private let settingsStore: SettingsStore
    private let subscriptions: SubscriptionManager

    init(index: SessionIndex, exporter: ExportManager, settingsStore: SettingsStore, subscriptions: SubscriptionManager) {
        self.index = index
        self.exporter = exporter
        self.settingsStore = settingsStore
        self.subscriptions = subscriptions
    }

    /// Exports every protected window of a drive that has not been exported yet.
    ///
    /// Returns the files written, so a caller — or a test — can check the work rather than
    /// trust the absence of an error.
    @discardableResult
    func exportProtectedFootage(ofSession sessionID: UUID) async -> [URL] {
        guard settingsStore.settings.autoExportProtected else { return [] }

        // Export is what the subscription buys. Doing it automatically does not make it
        // free, and failing silently here would look like the setting is broken — so the
        // outcome is recorded for the settings screen to explain.
        guard subscriptions.state.canExport else {
            lastOutcome = .skippedNoSubscription
            Log.export.info("Auto-export skipped: no entitlement")
            return []
        }

        guard let session = index.session(id: sessionID) else { return [] }
        let pending = session.protectedEvents
            .filter { $0.isActive && $0.autoExportedAt == nil }
            .sorted { $0.triggerDate < $1.triggerDate }
        guard !pending.isEmpty else { return [] }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        let canUsePhotos = status == .authorized || status == .limited
        if !canUsePhotos {
            // The file is still written to the app's exports folder, where the share
            // sheet can reach it. Denied permission loses the copy in Photos, not the
            // export.
            lastOutcome = .skippedNoPermission
            Log.export.info("Auto-export: photo library denied, keeping files in the app")
        }

        var written: [URL] = []
        for event in pending {
            guard let clip = clipRange(for: event, in: session) else { continue }
            do {
                let mode: ExportMode = session.frontSegments.isEmpty ? .rear : .pictureInPicture
                let urls = try await exporter.export(
                    session: session,
                    mode: mode,
                    style: .withInformation,
                    clip: clip,
                    includeProof: true
                )
                if canUsePhotos {
                    for url in urls where url.pathExtension == "mov" || url.pathExtension == "mp4" {
                        try await exporter.saveToPhotoLibrary(url)
                    }
                }
                index.markAutoExported(eventID: event.id)
                written.append(contentsOf: urls)
            } catch {
                lastOutcome = .failed(error.localizedDescription)
                Log.export.error("Auto-export failed: \(error.localizedDescription, privacy: .public)")
                return written
            }
        }

        if !written.isEmpty, lastOutcome == nil || canUsePhotos {
            lastOutcome = .exported(count: pending.count)
        }
        Log.export.info("Auto-exported \(pending.count) protected window(s) from session \(sessionID, privacy: .public)")
        return written
    }

    /// The event's window expressed against the drive's own clock, clamped to footage
    /// that actually exists — an impact ten seconds before the recording stopped has a
    /// forward half that was never filmed.
    private func clipRange(for event: ProtectedEvent, in session: DriveSession) -> SessionComposition.ClipRange? {
        let driveDuration = session.duration
        guard driveDuration > 0 else { return nil }
        let start = max(0, event.windowStart.timeIntervalSince(session.startedAt))
        let end = min(driveDuration, event.windowEnd.timeIntervalSince(session.startedAt))
        guard end > start else { return nil }
        return SessionComposition.ClipRange(start: start, duration: end - start)
    }
}
