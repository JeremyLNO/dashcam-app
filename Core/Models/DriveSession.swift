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
    /// Metres covered, accumulated from GPS fixes while recording. Zero when location was
    /// denied or never got a fix — which is not the same as "the car did not move", so
    /// the UI hides it rather than showing 0 km.
    var distanceMeters: Double
    /// Strongest acceleration seen during the drive, in g. Recorded whether or not it was
    /// strong enough to trigger an event.
    var peakGForce: Double

    @Relationship(deleteRule: .cascade, inverse: \VideoSegment.session)
    var segments: [VideoSegment]

    @Relationship(deleteRule: .cascade, inverse: \ProtectedEvent.session)
    var protectedEvents: [ProtectedEvent]

    @Relationship(deleteRule: .cascade, inverse: \LocationSample.session)
    var locationSamples: [LocationSample]

    @Relationship(deleteRule: .cascade, inverse: \MotionSample.session)
    var motionSamples: [MotionSample]

    init(id: UUID = UUID(), startedAt: Date = Date(), quality: VideoQuality = .standard) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.storageSize = 0
        self.qualityRaw = quality.rawValue
        self.distanceMeters = 0
        self.peakGForce = 0
        self.segments = []
        self.protectedEvents = []
        self.locationSamples = []
        self.motionSamples = []
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

    /// How many segments the *drive* has, not how many files are on disk.
    ///
    /// A dual-camera drive writes two files per window, so counting rows would tell the
    /// driver a nine-minute trip had eighteen segments. They think in windows.
    var segmentCount: Int {
        max(rearSegments.count, frontSegments.count)
    }

    /// Which cameras actually produced footage on this drive.
    ///
    /// Surfaced in the detail screen because "I only see the road camera" has two very
    /// different causes — an inset that failed to composite, or a cabin camera that never
    /// recorded — and nothing on screen used to tell them apart.
    var recordedCameras: [CameraPosition] {
        var cameras: [CameraPosition] = []
        if !rearSegments.isEmpty { cameras.append(.rear) }
        if !frontSegments.isEmpty { cameras.append(.front) }
        return cameras
    }

    var hasProtectedContent: Bool {
        segments.contains(where: \.isProtected)
    }

    var activeEvents: [ProtectedEvent] {
        protectedEvents.filter(\.isActive).sorted { $0.triggerDate < $1.triggerDate }
    }

    /// Nil when no GPS fix was ever recorded, so the library can stay silent instead of
    /// claiming a drive covered zero kilometres.
    var distanceKilometres: Double? {
        distanceMeters > 0 ? distanceMeters / 1000 : nil
    }

    /// Directory name on disk. Stable, derived from the id, and safe as a path component.
    var folderName: String { id.uuidString }
}
