import Foundation
import SwiftData

/// Why a protection window exists. Stored raw so the reason survives renames.
enum ProtectionOrigin: String, Codable, CaseIterable, Sendable {
    case manual
    case impact
    case carPlay

    var titleKey: String {
        switch self {
        case .manual: return "event.origin.manual"
        case .impact: return "event.origin.impact"
        case .carPlay: return "event.origin.carplay"
        }
    }
}

/// A window of time the user (or the impact detector) asked to keep.
///
/// The window is stored as dates rather than as a list of segment ids on purpose: the
/// forward half of the window usually covers footage that does not exist yet, and new
/// segments consult still-open events as they are finalized.
@Model
final class ProtectedEvent {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var triggerDate: Date
    var windowStart: Date
    var windowEnd: Date
    var originRaw: String
    /// Peak acceleration in g for impact events, 0 for manual ones.
    var magnitude: Double
    /// Cleared when the user removes protection; the event row is kept as history.
    var isActive: Bool

    var session: DriveSession?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        triggerDate: Date,
        lookBack: TimeInterval = RecordingSettings.protectionLookBack,
        lookAhead: TimeInterval = RecordingSettings.protectionLookAhead,
        origin: ProtectionOrigin,
        magnitude: Double = 0,
        isActive: Bool = true
    ) {
        self.id = id
        self.sessionID = sessionID
        self.triggerDate = triggerDate
        self.windowStart = triggerDate.addingTimeInterval(-lookBack)
        self.windowEnd = triggerDate.addingTimeInterval(lookAhead)
        self.originRaw = origin.rawValue
        self.magnitude = magnitude
        self.isActive = isActive
    }

    var origin: ProtectionOrigin { ProtectionOrigin(rawValue: originRaw) ?? .manual }

    /// Still accepting newly recorded segments, i.e. "now" has not passed `windowEnd`.
    func isOpen(at date: Date = Date()) -> Bool { isActive && date < windowEnd }

    func covers(_ segment: VideoSegment) -> Bool {
        isActive && segment.overlaps(start: windowStart, end: windowEnd)
    }
}
