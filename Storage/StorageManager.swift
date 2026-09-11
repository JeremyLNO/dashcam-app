import Foundation

/// What the Dashcam is using, and what is left.
struct StorageSnapshot: Equatable, Sendable {
    var dashcamBytes: Int64 = 0
    var protectedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var sessionCount: Int = 0
    var segmentCount: Int = 0
    var totalRecordedDuration: TimeInterval = 0

    var isCriticallyLow: Bool { freeBytes < RecordingSettings.criticalFreeSpace }

    /// How much more the app is still allowed to write: the smaller of "room under the
    /// user's cap" and "room on the disk above the safety floor".
    func writableBudget(limit: StorageLimit) -> Int64 {
        let diskRoom = max(0, freeBytes - RecordingSettings.criticalFreeSpace)
        guard let cap = limit.byteLimit else { return diskRoom }
        let capRoom = max(0, cap - dashcamBytes)
        return min(diskRoom, capRoom)
    }

    /// Rough time left at the current quality, both cameras running.
    func estimatedRemainingRecording(quality: VideoQuality, limit: StorageLimit, dualCamera: Bool) -> TimeInterval {
        let bitsPerSecond = Double(quality.bitrate * (dualCamera ? 2 : 1))
        guard bitsPerSecond > 0 else { return 0 }
        let bytesPerSecond = bitsPerSecond / 8
        return Double(writableBudget(limit: limit)) / bytesPerSecond
    }
}

/// Measures disk usage for the Dashcam and for the device.
///
/// Sizes are read from the filesystem rather than from the database: the database is an
/// index, and an index that has drifted (a crash between writing a file and inserting its
/// row) must not be able to hide megabytes from the sweeper.
@MainActor
final class StorageManager: ObservableObject {
    @Published private(set) var snapshot = StorageSnapshot()

    private let index: SessionIndex

    init(index: SessionIndex) {
        self.index = index
    }

    @discardableResult
    func refresh() -> StorageSnapshot {
        let sessions = index.allSessions()
        let segments = index.allSegments()

        var snapshot = StorageSnapshot()
        snapshot.dashcamBytes = Self.directorySize(StorageLocations.recordingsRoot)
        snapshot.protectedBytes = segments.filter(\.isProtected).reduce(0) { $0 + $1.fileSize }
        snapshot.sessionCount = sessions.count
        snapshot.segmentCount = segments.count
        snapshot.totalRecordedDuration = sessions.reduce(0) { $0 + $1.duration }

        let volume = Self.volumeCapacity()
        snapshot.freeBytes = volume.available
        snapshot.totalBytes = volume.total

        self.snapshot = snapshot
        return snapshot
    }

    /// Recursive byte count of a directory tree. Uses `totalFileAllocatedSize` so the
    /// number matches what the OS reports as used, not the logical file length.
    static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// "Important" capacity: what iOS will actually free up for content the user cares
    /// about, which is the number that matters before starting a long recording.
    static func volumeCapacity() -> (available: Int64, total: Int64) {
        let url = StorageLocations.recordingsRoot
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        return (Int64(available), total)
    }

    static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
