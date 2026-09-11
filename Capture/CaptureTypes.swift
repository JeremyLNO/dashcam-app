import AVFoundation
import Foundation

/// What the capture pipeline managed to put together on this particular device.
enum CaptureMode: Equatable, Sendable {
    /// Rear + front simultaneously through `AVCaptureMultiCamSession`.
    case dual
    /// Rear only — either the hardware cannot do multi-cam, or the user turned the
    /// cabin camera off.
    case rearOnly
    /// Nothing usable (no camera, permission denied, simulator).
    case unavailable
}

/// Why the pipeline is not running, in terms a driver can act on.
enum CaptureUnavailability: Equatable, Sendable {
    case simulator
    case noCamera
    case permissionDenied
    case configurationFailed(String)

    var messageKey: String {
        switch self {
        case .simulator: return "capture.error.simulator"
        case .noCamera: return "capture.error.no_camera"
        case .permissionDenied: return "capture.error.permission"
        case .configurationFailed: return "capture.error.configuration"
        }
    }
}

/// An interruption AVFoundation told us about, mapped to something displayable.
enum CaptureInterruption: Equatable, Sendable {
    case phoneCall
    case takenByAnotherApp
    case notRunnableInBackground
    case videoDeviceTemporarilyUnavailable
    case systemPressure
    /// iOS 26+ blanks the camera feed when it detects sensitive content.
    case sensitiveContentBlocked
    case unknown

    var messageKey: String {
        switch self {
        case .phoneCall: return "capture.interrupted.call"
        case .takenByAnotherApp: return "capture.interrupted.other_app"
        case .notRunnableInBackground: return "capture.interrupted.background"
        case .videoDeviceTemporarilyUnavailable: return "capture.interrupted.device"
        case .systemPressure: return "capture.interrupted.pressure"
        case .sensitiveContentBlocked: return "capture.interrupted.sensitive"
        case .unknown: return "capture.interrupted.unknown"
        }
    }

    init(reason: AVCaptureSession.InterruptionReason) {
        switch reason {
        case .audioDeviceInUseByAnotherClient: self = .phoneCall
        case .videoDeviceInUseByAnotherClient: self = .takenByAnotherApp
        case .videoDeviceNotAvailableInBackground: self = .notRunnableInBackground
        case .videoDeviceNotAvailableWithMultipleForegroundApps: self = .takenByAnotherApp
        case .videoDeviceNotAvailableDueToSystemPressure: self = .systemPressure
        default:
            // `.sensitiveContentMitigationActivated` only exists from iOS 26, so it is
            // matched behind an availability check rather than as a `case` — which would
            // not compile against the 17.0 floor.
            if #available(iOS 26.0, *), reason == .sensitiveContentMitigationActivated {
                self = .sensitiveContentBlocked
            } else {
                self = .unknown
            }
        }
    }
}

/// Snapshot of the pipeline, published to the UI and to CarPlay.
struct CaptureStatus: Equatable, Sendable {
    var mode: CaptureMode = .unavailable
    var unavailability: CaptureUnavailability?
    var isRunning: Bool = false
    var rearActive: Bool = false
    var frontActive: Bool = false
    var audioActive: Bool = false
    /// e.g. "Ultra Wide" / "Wide" — shown so the driver knows which lens is filming.
    var rearLensKey: String = "lens.unknown"
    var interruption: CaptureInterruption?
    /// 0…1, how much of the multi-cam hardware budget the configuration uses.
    var hardwareCost: Float = 0
    var systemPressureCost: Float = 0

    var isDual: Bool { mode == .dual }
}

/// Where a sample buffer came from. Kept out of `CameraPosition` because audio is a
/// source too but not a camera.
enum SampleSource: Equatable, Sendable {
    case rearVideo
    case frontVideo
    case audio
}

/// Anything that wants the raw stream. Implemented by `RecordingManager`.
///
/// Called on AVFoundation's capture queues, never on the main actor.
protocol SampleSink: AnyObject {
    func consume(_ sampleBuffer: CMSampleBuffer, from source: SampleSource)
    func handleDroppedSample(from source: SampleSource)
}

/// Video encoding parameters resolved from the user's quality choice and whatever the
/// hardware actually agreed to.
///
/// The size is expressed as a **short side**, not a width and a height, because the
/// frames arriving from the capture connection change shape when the phone is rotated in
/// its cradle: 1920×1080 held landscape, 1080×1920 held portrait. A quality tier means
/// "1080 across the narrow dimension" either way, so the same tier costs the same
/// bandwidth whichever way the phone is mounted.
struct VideoFormatDescriptor: Equatable, Sendable {
    /// 720 for Eco, 1080 for Standard and High.
    var targetShortSide: Int
    var fps: Int
    var bitrate: Int
    var codec: String

    static func resolved(for quality: VideoQuality, codec: String) -> VideoFormatDescriptor {
        VideoFormatDescriptor(
            targetShortSide: min(quality.dimensions.width, quality.dimensions.height),
            fps: quality.frameRate,
            bitrate: quality.bitrate,
            codec: codec
        )
    }

    /// Encoded size for frames of the given shape. Never upscales, preserves the aspect
    /// ratio exactly, and forces both dimensions even — odd dimensions are rejected
    /// outright by some HEVC encoder configurations.
    func encodeSize(forFrame width: Int, height: Int) -> (width: Int, height: Int) {
        func even(_ value: Int) -> Int { max(2, value - (value % 2)) }
        let shortSide = min(width, height)
        guard shortSide > targetShortSide, shortSide > 0 else {
            return (even(width), even(height))
        }
        let scale = Double(targetShortSide) / Double(shortSide)
        return (even(Int((Double(width) * scale).rounded())), even(Int((Double(height) * scale).rounded())))
    }
}
