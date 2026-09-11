import Foundation
import SwiftData

/// The only writer to the SwiftData store.
///
/// Everything that records metadata funnels through here on the main actor. That is a
/// deliberate simplification: the write rate is a handful of rows per minute (one per
/// finalized segment, one per GPS sample), which is nothing, and a single writer removes
/// a whole class of "two contexts disagree about the same session" bugs.
@MainActor
final class SessionIndex: ObservableObject {
    let context: ModelContext

    init(container: ModelContainer) {
        self.context = container.mainContext
        self.context.autosaveEnabled = true
    }

    // MARK: - Sessions

    @discardableResult
    func beginSession(id: UUID = UUID(), startedAt: Date = Date(), quality: VideoQuality) -> DriveSession {
        let session = DriveSession(id: id, startedAt: startedAt, quality: quality)
        context.insert(session)
        save()
        return session
    }

    func endSession(id: UUID, endedAt: Date = Date()) {
        guard let session = session(id: id) else { return }
        session.endedAt = endedAt
        session.storageSize = session.segments.reduce(0) { $0 + $1.fileSize }
        save()
    }

    func session(id: UUID) -> DriveSession? {
        let descriptor = FetchDescriptor<DriveSession>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func allSessions() -> [DriveSession] {
        let descriptor = FetchDescriptor<DriveSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Oldest first — the order the retention sweep consumes them in.
    func sessionsOldestFirst() -> [DriveSession] {
        let descriptor = FetchDescriptor<DriveSession>(sortBy: [SortDescriptor(\.startedAt, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteSession(_ session: DriveSession) {
        let folder = StorageLocations.recordingsRoot.appendingPathComponent(session.folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        context.delete(session)
        save()
    }

    /// Removes a session row only if nothing on disk survives — used after a sweep has
    /// deleted individual segments and left the session empty.
    func pruneIfEmpty(_ session: DriveSession) {
        guard session.segments.isEmpty else { return }
        deleteSession(session)
    }

    // MARK: - Segments

    @discardableResult
    func insertSegment(_ finished: FinishedSegment, sessionID: UUID, isProtected: Bool) -> VideoSegment? {
        guard finished.succeeded, let session = session(id: sessionID) else { return nil }
        let segment = VideoSegment(
            sessionID: sessionID,
            camera: finished.camera,
            index: finished.index,
            startDate: finished.startDate,
            endDate: finished.endDate,
            relativePath: finished.relativePath,
            fileSize: finished.fileSize,
            isProtected: isProtected,
            width: finished.width,
            height: finished.height,
            fps: finished.fps,
            codec: finished.codec,
            isFinalized: true
        )
        segment.session = session
        context.insert(segment)
        session.storageSize += finished.fileSize
        save()
        return segment
    }

    func allSegments() -> [VideoSegment] {
        let descriptor = FetchDescriptor<VideoSegment>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func unprotectedSegmentsOldestFirst() -> [VideoSegment] {
        let descriptor = FetchDescriptor<VideoSegment>(
            predicate: #Predicate { $0.isProtected == false },
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteSegment(_ segment: VideoSegment) {
        let url = StorageLocations.absoluteURL(forRelativePath: segment.relativePath)
        try? FileManager.default.removeItem(at: url)
        if let session = segment.session {
            session.storageSize = max(0, session.storageSize - segment.fileSize)
        }
        context.delete(segment)
        save()
    }

    // MARK: - Protection

    @discardableResult
    func insertProtectedEvent(sessionID: UUID, triggerDate: Date, origin: ProtectionOrigin, magnitude: Double = 0) -> ProtectedEvent? {
        guard let session = session(id: sessionID) else { return nil }
        let event = ProtectedEvent(sessionID: sessionID, triggerDate: triggerDate, origin: origin, magnitude: magnitude)
        event.session = session
        context.insert(event)
        save()
        return event
    }

    func openEvents(at date: Date = Date()) -> [ProtectedEvent] {
        let descriptor = FetchDescriptor<ProtectedEvent>(predicate: #Predicate { $0.isActive == true })
        let events = (try? context.fetch(descriptor)) ?? []
        return events.filter { $0.isOpen(at: date) }
    }

    func activeEvents(forSession sessionID: UUID) -> [ProtectedEvent] {
        let descriptor = FetchDescriptor<ProtectedEvent>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.isActive == true }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Location

    func appendLocationSample(
        sessionID: UUID, timestamp: Date, latitude: Double, longitude: Double,
        speed: Double, course: Double, altitude: Double, accuracy: Double
    ) {
        guard let session = session(id: sessionID) else { return }
        let sample = LocationSample(
            sessionID: sessionID, timestamp: timestamp, latitude: latitude, longitude: longitude,
            speed: speed, course: course, altitude: altitude, horizontalAccuracy: accuracy
        )
        sample.session = session
        context.insert(sample)
    }

    /// Samples covering a time window, used to stamp speed/position on an export.
    func locationSamples(sessionID: UUID, from start: Date, to end: Date) -> [LocationSample] {
        let descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: -

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Log.storage.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
