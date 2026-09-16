import AVFoundation
import Foundation

/// Steers the camera's exposure with what the sensor is already measuring.
///
/// Automatic exposure is built for photographs of people, and a windscreen is neither.
/// Three situations break it, and all three are ordinary driving:
///
/// * **Night.** To brighten a dark road the camera lengthens the shutter. A plate moving
///   at 50 km/h then smears across the frame — the image looks fine and reads nothing.
///   Capping the exposure duration keeps the frame darker and legible, which is the only
///   trade that matters here.
/// * **Snow, or a wet road in full sun.** A light meter assumes the world averages to
///   mid-grey, so it darkens a white scene until the snow is grey and everything in front
///   of it is a silhouette. Lifting the exposure bias undoes that.
/// * **Backlight and tunnels.** The range between the sky and the road exceeds what one
///   exposure can hold. Video HDR is what the hardware offers for it, when the chosen
///   format supports it.
///
/// Nothing here is clever: it reads ISO and shutter from the device four times a second,
/// classifies the scene from those two numbers, and nudges bias and shutter cap. There is
/// no model, no training, nothing to be wrong about in a way the driver cannot see — and
/// it can be switched off in Settings.
final class SceneOptimiser {
    /// What the sensor says about the world right now.
    enum Scene: String {
        /// Ordinary daylight. The camera is left alone.
        case neutral
        /// Very bright and likely to be misread as over-exposed: snow, sand, low sun.
        case bright
        /// Dark enough that the shutter is the thing to watch.
        case dark

        var exposureBias: Float {
            switch self {
            case .neutral: return 0
            // Two thirds of a stop: enough to keep snow white, not enough to blow out a
            // sky that was correctly exposed to begin with.
            case .bright: return 0.67
            case .dark: return 0.3
            }
        }
    }

    /// Shutter never slower than this while driving: 1/60 s is about the point where a
    /// plate at urban speed stops resolving.
    static let darkShutterCap = CMTime(value: 1, timescale: 60)
    /// What the camera uses when nothing is capping it. `AVCaptureDevice` names this
    /// `activeMaxExposureDurationCurrent` in its documentation but exports no such symbol;
    /// the sentinel is an invalid time, which the framework reads as "no cap".
    private static let uncappedExposureDuration = CMTime.invalid
    /// Thresholds come in **pairs** — one to enter a scene, one to leave it — and the
    /// reason is not tidiness, it is that a single threshold here oscillates by
    /// construction.
    ///
    /// `apply(.dark)` caps the shutter at 1/60 s. The old rule entered `.dark` at a shutter
    /// of 1/45 s or slower. So the moment the cap took effect the shutter was *faster* than
    /// the threshold that had just classified the scene as dark: next tick, neutral; cap
    /// removed; shutter lengthens again; dark. **Four times a second, for as long as it was
    /// dark** — and every one of those flips took a device lock on a running camera, which
    /// is a visible hitch in the picture. From the driver's seat: « the video stream keeps
    /// cutting out, and there is no interruption ».
    ///
    /// The remedy erased its own cause. The shape of that mistake is worth more than the
    /// numbers: whenever a control loop *acts on* the quantity it also *measures*, the
    /// action has to be taken out of the measurement — here, by ignoring the shutter once
    /// dark, since that shutter is our own cap talking rather than the world.
    private static let darkISOEnter: Float = 1_000
    private static let darkISOLeave: Float = 700
    private static let brightISOEnter: Float = 60
    private static let brightISOLeave: Float = 120
    /// Only ever used to *enter* the dark scene, never to leave it.
    private static let darkShutterEnter = 1.0 / 45

    /// And a floor under how often the scene may change at all, whatever the numbers say.
    /// A tunnel mouth is one change; a hedge flickering across a low sun is not four a
    /// second. Hysteresis handles the loop above; this handles everything else.
    static let minimumDwell: TimeInterval = 3

    /// Video HDR doubles what a format asks of the image pipeline. On a single camera
    /// that is affordable; running two cameras at once, it competes with the recording
    /// itself for a hardware budget that is already spoken for.
    var allowsHDR = true

    private weak var device: AVCaptureDevice?
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private(set) var scene: Scene = .neutral
    private var lastChange = Date.distantPast

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Applies the one-off settings a format allows, then starts watching the scene.
    func start(on device: AVCaptureDevice) {
        stop()
        self.device = device

        configureOnce(device)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        guard let device else { return }
        // Hand the camera back as it was found: a cap left behind would follow the user
        // into every other app that picks this device up next.
        try? device.lockForConfiguration()
        device.activeMaxExposureDuration = Self.uncappedExposureDuration
        device.setExposureTargetBias(0, completionHandler: nil)
        device.unlockForConfiguration()
        self.device = nil
    }

    // MARK: - Internals

    private func configureOnce(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if allowsHDR, device.activeFormat.isVideoHDRSupported {
            // Left to its own judgement the camera turns HDR on and off mid-drive, which
            // shows up as a visible exposure jump at every tunnel mouth.
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = true
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
    }

    private func tick() {
        guard let device else { return }
        let iso = device.iso
        let shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
        let newScene = classify(iso: iso, shutterSeconds: shutterSeconds, current: scene)
        guard newScene != scene else { return }
        // Each change locks the camera for configuration, which the picture shows. Rare is
        // the point.
        guard Date().timeIntervalSince(lastChange) >= Self.minimumDwell else { return }
        lastChange = Date()
        scene = newScene
        apply(newScene, to: device)
        Log.capture.debug("Scene now \(newScene.rawValue, privacy: .public) (ISO \(Int(iso)), \(shutterSeconds, privacy: .public)s)")
    }

    /// Keeps a requested cap inside the range the format allows. Out of bounds is not a
    /// wrong picture, it is an exception thrown at the camera.
    static func cap(_ requested: CMTime, within format: AVCaptureDevice.Format) -> CMTime {
        let shortest = CMTimeGetSeconds(format.minExposureDuration)
        let longest = CMTimeGetSeconds(format.maxExposureDuration)
        let wanted = CMTimeGetSeconds(requested)
        guard shortest > 0, longest > 0 else { return requested }
        let clamped = min(max(wanted, shortest), longest)
        return CMTime(seconds: clamped, preferredTimescale: 1_000_000)
    }

    /// Internal rather than private: the boundaries between the three scenes are the part
    /// worth testing, and they are pure arithmetic on two numbers **and the scene already
    /// in force** — which is the whole correction. A classifier that does not know where it
    /// is cannot tell a reading from its own doing.
    func classify(iso: Float, shutterSeconds: Double, current: Scene) -> Scene {
        switch current {
        case .dark:
            // The shutter is deliberately not consulted here: while dark, it is pinned by
            // the cap this class applied, so reading it is reading our own hand. Only the
            // light itself — the ISO — can say the night is over, and it has to say it
            // clearly before the cap is given up.
            return iso <= Self.darkISOLeave ? enteringScene(iso: iso, shutterSeconds: shutterSeconds) : .dark
        case .bright:
            return iso >= Self.brightISOLeave ? enteringScene(iso: iso, shutterSeconds: shutterSeconds) : .bright
        case .neutral:
            return enteringScene(iso: iso, shutterSeconds: shutterSeconds)
        }
    }

    /// The thresholds for *arriving* somewhere, which sit further out than those for
    /// leaving.
    private func enteringScene(iso: Float, shutterSeconds: Double) -> Scene {
        if iso >= Self.darkISOEnter || shutterSeconds >= Self.darkShutterEnter { return .dark }
        if iso <= Self.brightISOEnter { return .bright }
        return .neutral
    }

    private func apply(_ scene: Scene, to device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        let bias = min(max(scene.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(bias, completionHandler: nil)

        // The cap is only worth paying for in the dark; in daylight the shutter is
        // already far shorter than the cap and forcing it changes nothing but noise.
        //
        // Clamped to what the active format accepts: AVFoundation throws an
        // NSRangeException for a duration outside it, and a format whose shortest
        // exposure is longer than the cap exists — on a lens with a fixed low frame rate,
        // for one.
        if scene == .dark {
            device.activeMaxExposureDuration = Self.cap(Self.darkShutterCap, within: device.activeFormat)
        } else {
            device.activeMaxExposureDuration = Self.uncappedExposureDuration
        }
    }
}
