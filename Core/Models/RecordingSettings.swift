import Foundation

// MARK: - Camera

/// Which physical camera a piece of footage came from. Persisted as a raw string so a
/// renamed case can never silently repoint existing rows at the wrong camera.
enum CameraPosition: String, Codable, CaseIterable, Sendable {
    case rear
    case front

    var localizedNameKey: String {
        switch self {
        case .rear: return "camera.rear"
        case .front: return "camera.front"
        }
    }
}

// MARK: - Quality

/// User-facing quality tiers. Deliberately three coarse steps — the spec is explicit
/// that raw codec/bitrate knobs must not be exposed.
enum VideoQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case eco
    case standard
    case high

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .eco: return "quality.eco"
        case .standard: return "quality.standard"
        case .high: return "quality.high"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .eco: return (1280, 720)
        case .standard, .high: return (1920, 1080)
        }
    }

    var frameRate: Int { 30 }

    /// Target bits/second for one camera. HEVC at these rates is comfortably above the
    /// "readable licence plate" threshold that matters for a dashcam.
    var bitrate: Int {
        switch self {
        case .eco: return 4_000_000
        case .standard: return 8_000_000
        case .high: return 14_000_000
        }
    }

    /// Storage estimate for a *dual* stream recording (rear + front), in gigabytes per
    /// hour. Shown next to each tier so the trade-off is concrete.
    var gigabytesPerHour: Double {
        let bitsPerHour = Double(bitrate * 2) * 3600
        return bitsPerHour / 8 / 1_000_000_000
    }

    /// The next tier down, used by ThermalManager when the device is under pressure.
    var degraded: VideoQuality? {
        switch self {
        case .high: return .standard
        case .standard: return .eco
        case .eco: return nil
        }
    }
}

// MARK: - Segmentation

enum SegmentDuration: Int, Codable, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var titleKey: String {
        switch self {
        case .oneMinute: return "segment.1min"
        case .threeMinutes: return "segment.3min"
        case .fiveMinutes: return "segment.5min"
        }
    }
}

// MARK: - Retention

enum RetentionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case never

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .sevenDays: return "retention.7days"
        case .thirtyDays: return "retention.30days"
        case .never: return "retention.never"
        }
    }

    /// `nil` means "keep forever" — the age sweep is skipped entirely.
    var maxAge: TimeInterval? {
        switch self {
        case .sevenDays: return 7 * 24 * 3600
        case .thirtyDays: return 30 * 24 * 3600
        case .never: return nil
        }
    }
}

// MARK: - Storage cap

enum StorageLimit: String, Codable, CaseIterable, Identifiable, Sendable {
    case gb5
    case gb10
    case gb25
    case gb50
    case unlimited

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .gb5: return "storage.5gb"
        case .gb10: return "storage.10gb"
        case .gb25: return "storage.25gb"
        case .gb50: return "storage.50gb"
        case .unlimited: return "storage.unlimited"
        }
    }

    /// `nil` means uncapped — only the free-disk safety floor still applies.
    var byteLimit: Int64? {
        switch self {
        case .gb5: return 5 * 1_000_000_000
        case .gb10: return 10 * 1_000_000_000
        case .gb25: return 25 * 1_000_000_000
        case .gb50: return 50 * 1_000_000_000
        case .unlimited: return nil
        }
    }
}

// MARK: - Impact detection

enum ShockSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .low: return "shock.low"
        case .normal: return "shock.normal"
        case .high: return "shock.high"
        }
    }

    /// Peak jerk-corrected acceleration, in g, that has to be exceeded. "Low" means
    /// "only a real collision"; "high" fires more readily and accepts more noise.
    var thresholdG: Double {
        switch self {
        case .low: return 3.5
        case .normal: return 2.5
        case .high: return 1.8
        }
    }
}

// MARK: - Discreet screen

enum DiscreetDelay: Int, Codable, CaseIterable, Identifiable, Sendable {
    case never = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .never: return "discreet.never"
        case .fiveSeconds: return "discreet.5s"
        case .tenSeconds: return "discreet.10s"
        case .thirtySeconds: return "discreet.30s"
        }
    }

    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

// MARK: - Overlay

/// Which pieces of metadata the *exported* file may be stamped with. The stored files
/// themselves always stay clean — see `ExportManager`.
struct OverlayFields: OptionSet, Codable, Sendable {
    let rawValue: Int

    static let date = OverlayFields(rawValue: 1 << 0)
    static let time = OverlayFields(rawValue: 1 << 1)
    static let location = OverlayFields(rawValue: 1 << 2)
    static let speed = OverlayFields(rawValue: 1 << 3)

    static let `default`: OverlayFields = [.date, .time, .speed]
}

// MARK: - Settings aggregate

/// Every user preference in one Codable value. Persisted by `SettingsStore`; the whole
/// struct is replaced on each change, which keeps observers trivially correct.
struct RecordingSettings: Codable, Equatable, Sendable {
    var quality: VideoQuality = .standard
    var segmentDuration: SegmentDuration = .threeMinutes
    var recordAudio: Bool = false
    var retention: RetentionPolicy = .thirtyDays
    var storageLimit: StorageLimit = .gb10
    var autoStartOnLaunch: Bool = false
    /// Start recording as soon as the phone connects to CarPlay — but only while the app
    /// is already running. iOS gives no app the power to launch itself; the Shortcuts
    /// automation described in the settings footer covers the rest.
    var startOnCarPlayConnect: Bool = false
    var discreetDelay: DiscreetDelay = .never
    var impactDetectionEnabled: Bool = true
    var shockSensitivity: ShockSensitivity = .normal
    /// Sustained heavy deceleration also protects the footage around it.
    var harshBrakingDetectionEnabled: Bool = true
    var locationMetadataEnabled: Bool = true
    var overlayEnabled: Bool = true
    var overlayFields: OverlayFields = .default
    var frontCameraEnabled: Bool = true
    /// Export a protected window by itself as soon as the drive ends. Off by default:
    /// nothing writes to someone's photo library unasked. Needs a subscription, like every
    /// other export.
    var autoExportProtected: Bool = false

    /// Face ID / Touch ID before the video library opens. Off by default: a lock the
    /// driver did not ask for is a lock between them and their own evidence.
    var requireBiometricUnlock: Bool = false

    /// How far back a *manual* Protect reaches, and how far forward it holds.
    ///
    /// Generous on purpose: a driver presses the button after realising something
    /// happened, which is seconds to minutes late.
    static let protectionLookBack: TimeInterval = 5 * 60
    static let protectionLookAhead: TimeInterval = 2 * 60

    /// The window around an *automatically detected* event.
    ///
    /// Tight, because the sensor knows the exact instant — there is no reaction delay to
    /// compensate for. Ten seconds either side covers the approach and the aftermath.
    static let automaticLookBack: TimeInterval = 10
    static let automaticLookAhead: TimeInterval = 10

    /// Below this much free space the recorder stops rather than risk corrupting files.
    static let criticalFreeSpace: Int64 = 1_000_000_000

    /// Deceleration, in g, that has to be sustained for `harshBrakingMinimumDuration`
    /// before it counts as harsh braking rather than ordinary slowing down. Roughly 0.5 g
    /// is an emergency stop in a road car; normal city braking sits well under 0.3 g.
    static let harshBrakingThresholdG: Double = 0.47
    static let harshBrakingMinimumDuration: TimeInterval = 0.45
}
