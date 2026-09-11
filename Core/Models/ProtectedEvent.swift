import Foundation
import SwiftData

/// Why a protection window exists. Stored raw so the reason survives renames.
enum ProtectionOrigin: String, Codable, CaseIterable, Sendable {
    case manual
    case impact
    /// Sustained heavy deceleration. Deliberately distinct from `impact`: the two have
    /// opposite signatures — a collision is a step, harsh braking is a ramp — and a
    /// driver reading their history wants to tell them apart.
    case harshBraking
    case carPlay

    var titleKey: String {
        switch self {
        case .manual: return "event.origin.manual"
        case .impact: return "event.origin.impact"
        case .harshBraking: return "event.origin.braking"
        case .carPlay: return "event.origin.carplay"
        }
    }

    /// How far the protection reaches on either side of the trigger.
    ///
    /// It depends on who pulled the trigger, not on what happened. A human presses the
    /// button late and needs minutes of history; the accelerometer timestamps the instant
    /// itself and needs seconds.
    var lookBack: TimeInterval {
        switch self {
        case .manual, .carPlay: return RecordingSettings.protectionLookBack
        case .impact, .harshBraking: return RecordingSettings.automaticLookBack
        }
    }

    var lookAhead: TimeInterval {
        switch self {
        case .manual, .carPlay: return RecordingSettings.protectionLookAhead
        case .impact, .harshBraking: return RecordingSettings.automaticLookAhead
        }
    }

    var symbolName: String {
        switch self {
        case .manual: return "hand.tap.fill"
        case .impact: return "burst.fill"
        case .harshBraking: return "exclamationmark.brakesignal"
        case .carPlay: return "car.fill"
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
        origin: ProtectionOrigin,
        lookBack: TimeInterval? = nil,
        lookAhead: TimeInterval? = nil,
        magnitude: Double = 0,
        isActive: Bool = true
    ) {
        self.id = id
        self.sessionID = sessionID
        self.triggerDate = triggerDate
        // The origin decides the window unless a caller overrides it, so there is exactly
        // one place that knows how long each kind of event reaches.
        self.windowStart = triggerDate.addingTimeInterval(-(lookBack ?? origin.lookBack))
        self.windowEnd = triggerDate.addingTimeInterval(lookAhead ?? origin.lookAhead)
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
