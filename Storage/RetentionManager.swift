import Foundation

/// Why a sweep ran. Only used for logging and for deciding how aggressive to be.
enum SweepReason: String, Sendable {
    case launch
    case recordingFinished
    case periodic
    case lowSpace
    case settingsChanged
}

/// Outcome of one sweep, returned so callers (and tests) can assert on it.
struct SweepResult: Equatable, Sendable {
    var deletedSegments: Int = 0
    var reclaimedBytes: Int64 = 0
    var deletedSessions: Int = 0
    /// True when the sweep could not get back under the safety floor because everything
    /// left is protected or in use. The recorder must stop in that case.
    var stillCritical: Bool = false
}

/// Enforces the two retention rules — maximum age and maximum total size — plus the
/// hard floor on free disk space.
///
/// Three things are never deleted, in this order of priority:
///   1. a protected segment, whatever the rule that wanted it gone;
///   2. a segment reserved in `ActiveFileRegistry` (being recorded, or being exported);
///   3. nothing else — beyond those two, oldest goes first.
@MainActor
final class RetentionManager: ObservableObject {
    @Published private(set) var lastResult: SweepResult?
    @Published private(set) var lastSweepDate: Date?

    private let index: SessionIndex
    private let storage: StorageManager
    private let registry: ActiveFileRegistry

    init(index: SessionIndex, storage: StorageManager, registry: ActiveFileRegistry) {
        self.index = index
        self.storage = storage
        self.registry = registry
    }

    @discardableResult
    func sweep(settings: RecordingSettings, reason: SweepReason, now: Date = Date()) -> SweepResult {
        var result = SweepResult()

        applyAgePolicy(settings.retention, now: now, into: &result)
        applySizeLimit(settings.storageLimit, into: &result)
        applyFreeSpaceFloor(into: &result)

        // Sessions whose every segment is gone are dead weight in the library.
        for session in index.sessionsOldestFirst() where session.segments.isEmpty && !session.isOpen {
            index.deleteSession(session)
            result.deletedSessions += 1
        }

        let snapshot = storage.refresh()
        result.stillCritical = snapshot.isCriticallyLow

        lastResult = result
        lastSweepDate = now
        Log.storage.info("Sweep(\(reason.rawValue, privacy: .public)): -\(result.deletedSegments) segments, \(result.reclaimedBytes) bytes, critical=\(result.stillCritical)")
        return result
    }

    // MARK: - Rules

    private func applyAgePolicy(_ policy: RetentionPolicy, now: Date, into result: inout SweepResult) {
        guard let maxAge = policy.maxAge else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        for segment in index.unprotectedSegmentsOldestFirst() where segment.endDate < cutoff {
            delete(segment, into: &result)
        }
    }

    private func applySizeLimit(_ limit: StorageLimit, into result: inout SweepResult) {
        guard let cap = limit.byteLimit else { return }
        var used = storage.refresh().dashcamBytes
        guard used > cap else { return }

        for segment in index.unprotectedSegmentsOldestFirst() {
            guard used > cap else { break }
            let size = segment.fileSize
            if delete(segment, into: &result) { used -= size }
        }
    }

    /// The last line of defence: free space below 1 GB. Deletes oldest-first regardless
    /// of the user's retention choice, because the alternative is a failed write.
    private func applyFreeSpaceFloor(into result: inout SweepResult) {
        var free = StorageManager.volumeCapacity().available
        guard free < RecordingSettings.criticalFreeSpace else { return }

        for segment in index.unprotectedSegmentsOldestFirst() {
            guard free < RecordingSettings.criticalFreeSpace else { break }
            let size = segment.fileSize
            if delete(segment, into: &result) { free += size }
        }
    }

    @discardableResult
    private func delete(_ segment: VideoSegment, into result: inout SweepResult) -> Bool {
        guard !segment.isProtected else { return false }
        guard !registry.isReserved(segment.relativePath) else { return false }
        let size = segment.fileSize
        index.deleteSegment(segment)
        result.deletedSegments += 1
        result.reclaimedBytes += size
        return true
    }
}
