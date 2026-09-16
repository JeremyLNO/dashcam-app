import AVFoundation

/// What the app asks of the phone's audio session, and the one option that decides whether
/// the driver keeps their music.
///
/// The app used to ask for nothing at all. `AVCaptureSession` then configures the session
/// itself — `automaticallyConfiguresApplicationAudioSession` defaults to `true` — and the
/// category it picks for a microphone input **stops whatever else was playing**. Starting a
/// drive killed Spotify; starting Spotify took the session back and stalled the capture
/// graph, video included, because an interrupted audio unit does not stop politely at the
/// boundary of its own media type.
///
/// So the session is configured here, deliberately, with `mixWithOthers`. A dashcam that
/// silences the car to film the road has misunderstood which of the two the driver came
/// for.
///
/// ⚠️ The honest consequence, which no option removes: while music plays *and* audio
/// recording is on, the microphone hears the car speakers, so the drive's soundtrack is the
/// music. The only way out of that is the app's existing « Record audio » switch, which is
/// the driver's call and not the app's.
enum AudioSessionPolicy {
    struct Configuration: Equatable {
        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode
        var options: AVAudioSession.CategoryOptions
    }

    /// Returns nil when the app has no business touching the session at all.
    ///
    /// A drive filmed without sound needs no microphone and therefore no category: leaving
    /// the session alone is strictly better than claiming it politely, because the only
    /// thing a claim can do here is take something away from another app.
    static func configuration(recordsAudio: Bool) -> Configuration? {
        guard recordsAudio else { return nil }
        return Configuration(
            category: .playAndRecord,
            mode: .videoRecording,
            // `mixWithOthers` is the whole point. `allowBluetooth` and its A2DP companion
            // keep the car's own route available — a hands-free kit and CarPlay both arrive
            // this way, and a `playAndRecord` session without them can drag playback back
            // to the phone's speaker.
            options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
        )
    }

    /// Whether a configuration would take the car's music away. Kept as a question rather
    /// than a comment because it is the one property of this file worth a test.
    static func leavesOtherAudioPlaying(_ configuration: Configuration?) -> Bool {
        guard let configuration else { return true }
        return configuration.options.contains(.mixWithOthers)
    }
}
