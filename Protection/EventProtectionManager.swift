import Foundation

/// Turns "keep this" into a durable fact about files on disk.
///
/// A protect action covers a window that straddles *now*: five minutes of footage that
/// already exists, and two minutes that does not exist yet. Those two halves need
/// different mechanics, and both live here:
///
/// * the past half marks every already-indexed segment that overlaps the window;
/// * the future half leaves the event *open*, and `RecordingManager` asks this manager
///   about every segment it finalizes until the window closes.
///
/// A window can and routinely does span several segments — at a 1-minute segment length
/// a single protect action pins eight files.
@MainActor
final class EventProtectionManager: ObservableObject {
    private let index: SessionIndex

    /// Bumped whenever protection changes, so the library refreshes without polling.
    @Published private(set) var revision: Int = 0

    init(index: SessionIndex) {
        self.index = index
    }

    /// Creates a protected event and pins everything already recorded inside its window.
    /// Returns the number of existing segments that became protected.
    @discardableResult
    func protect(
        sessionID: UUID,
        triggerDate: Date = Date(),
        origin: ProtectionOrigin,
        magnitude: Double = 0
    ) -> Int {
        guard let event = index.insertProtectedEvent(
            sessionID: sessionID, triggerDate: triggerDate, origin: origin, magnitude: magnitude
        ) else { return 0 }

        var pinned = 0
        if let session = index.session(id: sessionID) {
            for segment in session.segments where event.covers(segment) && !segment.isProtected {
                segment.isProtected = true
                pinned += 1
            }
        }
        index.save()
        revision += 1
        Log.storage.info("Protected \(pinned) existing segment(s); window open until \(event.windowEnd, privacy: .public)")
        return pinned
    }

    /// Asked by `RecordingManager` for each freshly finalized segment: does any still-open
    /// event claim it?
    func shouldProtectSegment(sessionID: UUID, start: Date, end: Date) -> Bool {
        index.activeEvents(forSession: sessionID).contains { event in
            start < event.windowEnd && end > event.windowStart
        }
    }

    /// Manual protection of a whole drive from the library.
    func setProtection(_ isProtected: Bool, for session: DriveSession) {
        for segment in session.segments {
            segment.isProtected = isProtected
        }
        if !isProtected {
            // Deactivating the events too, otherwise the next finalized segment inside a
            // still-open window would immediately re-protect what the user just released.
            for event in index.activeEvents(forSession: session.id) {
                event.isActive = false
            }
        }
        index.save()
        revision += 1
    }

    func setProtection(_ isProtected: Bool, for segment: VideoSegment) {
        segment.isProtected = isProtected
        index.save()
        revision += 1
    }

    /// Drops one event and releases any segment that no other event still claims.
    func removeProtection(event: ProtectedEvent) {
        event.isActive = false
        guard let session = index.session(id: event.sessionID) else {
            index.save(); revision += 1; return
        }
        let remaining = index.activeEvents(forSession: event.sessionID)
        for segment in session.segments where segment.isProtected {
            let stillClaimed = remaining.contains { $0.covers(segment) }
            if !stillClaimed { segment.isProtected = false }
        }
        index.save()
        revision += 1
    }
}
