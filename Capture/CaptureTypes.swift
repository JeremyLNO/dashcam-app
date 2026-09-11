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

/// Video encoding parameters resolved from the user's quality choice.
///
/// The output is **always landscape**, whatever way the phone is cradled. Dashcam footage
/// is widescreen by nature, and a portrait file is awkward everywhere it matters — an
/// insurer's viewer, a TV, a police report.
///
/// Holding the phone upright does not widen the lens — the sensor still sees a tall,
/// narrow slice of the road. What the app guarantees is a full landscape *picture*: the
/// upright image is scaled to fill the 16:9 box and cropped top and bottom
/// (`AVVideoScalingModeResizeAspectFill`), never letterboxed. Letterboxing produced a file
/// with landscape dimensions whose picture was a strip between black bars, which is not a
/// landscape video in any sense that matters — and which vanished entirely once shrunk
/// into the cabin inset.
struct VideoFormatDescriptor: Equatable, Sendable {
    /// Always the wider of the two, i.e. 1280×720 or 1920×1080.
    var outputWidth: Int
    var outputHeight: Int
    var fps: Int
    var bitrate: Int
    var codec: String

    var outputSize: (width: Int, height: Int) { (outputWidth, outputHeight) }

    static func resolved(for quality: VideoQuality, codec: String) -> VideoFormatDescriptor {
        let dimensions = quality.dimensions
        return VideoFormatDescriptor(
            outputWidth: max(dimensions.width, dimensions.height),
            outputHeight: min(dimensions.width, dimensions.height),
            fps: quality.frameRate,
            bitrate: quality.bitrate,
            codec: codec
        )
    }
}
