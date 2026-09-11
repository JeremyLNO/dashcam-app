import Foundation
import SwiftData

/// One drive: everything recorded between a Start and the matching Stop.
///
/// Deliberately holds no video bytes — only metadata and *relative* file paths. The
/// app container is re-rooted by iOS between launches and after restore, so an absolute
/// URL persisted today points nowhere tomorrow.
@Model
final class DriveSession {
    // (`#Index` would help the library queries here, but it needs iOS 18 and the
    //  deployment floor is 17 so older iPhones can still run rear-only.)

    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    /// Cached sum of every segment file size. Recomputed by `StorageManager` rather than
    /// trusted blindly, but good enough to sort and display without touching the disk.
    var storageSize: Int64
    /// Quality the drive was recorded at, as a raw value (see `VideoQuality`).
    var qualityRaw: String

    @Relationship(deleteRule: .cascade, inverse: \VideoSegment.session)
    var segments: [VideoSegment]

    @Relationship(deleteRule: .cascade, inverse: \ProtectedEvent.session)
    var protectedEvents: [ProtectedEvent]

    @Relationship(deleteRule: .cascade, inverse: \LocationSample.session)
    var locationSamples: [LocationSample]

    init(id: UUID = UUID(), startedAt: Date = Date(), quality: VideoQuality = .standard) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.storageSize = 0
        self.qualityRaw = quality.rawValue
        self.segments = []
        self.protectedEvents = []
        self.locationSamples = []
    }

    var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .standard }

    /// Wall-clock length of the drive. Falls back to the last segment's end while the
    /// session is still open so the library never shows 0:00 for an in-progress drive.
    var duration: TimeInterval {
        let end = endedAt ?? segments.map(\.endDate).max() ?? startedAt
        return max(0, end.timeIntervalSince(startedAt))
    }

    var isOpen: Bool { endedAt == nil }

    var rearSegments: [VideoSegment] {
        segments.filter { $0.camera == .rear }.sorted { $0.index < $1.index }
    }

    var frontSegments: [VideoSegment] {
        segments.filter { $0.camera == .front }.sorted { $0.index < $1.index }
    }

    var hasProtectedContent: Bool {
        segments.contains(where: \.isProtected)
    }

    /// Directory name on disk. Stable, derived from the id, and safe as a path component.
    var folderName: String { id.uuidString }
}
