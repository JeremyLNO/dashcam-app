import AVFoundation
import Combine
import Foundation
import UIKit

/// Owns the AVFoundation graph: devices, inputs, outputs, manual connections and the two
/// preview layers.
///
/// Design notes that matter:
///
/// * Nothing about the multi-cam combination is assumed. The device set is *looked up*
///   in `supportedMultiCamDeviceSets`, and if no set pairing a back and a front camera
///   exists the pipeline degrades to rear-only instead of failing.
/// * Outputs are `AVCaptureVideoDataOutput`, not `AVCaptureMovieFileOutput`. Segmenting
///   a movie file output means stopping and restarting it, which drops frames at every
///   boundary; feeding an `AVAssetWriter` lets `SegmentWriter` cut on a frame boundary
///   with no gap.
/// * Every session mutation happens on `sessionQueue`; every `@Published` mutation
///   happens on the main actor. The two never cross.
@MainActor
final class CaptureManager: ObservableObject {
    @Published private(set) var status = CaptureStatus()

    /// Preview layers are created once and reused. They are connected manually because a
    /// multi-cam session cannot auto-connect two previews to two cameras.
    /// `nonisolated(unsafe)` throughout this section is load-bearing, not a shortcut:
    /// every one of these objects is created once and then mutated exclusively on
    /// `sessionQueue`. Marking them main-actor would be a lie the compiler happens to
    /// accept, and would force a hop to the main thread in the middle of configuring a
    /// live capture graph.
    nonisolated(unsafe) let rearPreviewLayer = AVCaptureVideoPreviewLayer()
    nonisolated(unsafe) let frontPreviewLayer = AVCaptureVideoPreviewLayer()

    /// Set by `AppEnvironment` to the recording manager. Stored on the router so the
    /// capture queues never reach into main-actor state to find it.
    weak var sampleSink: SampleSink? {
        didSet { router.sink = sampleSink }
    }

    nonisolated(unsafe) private let router = SampleRouter()

    private let sessionQueue = DispatchQueue(label: "dashcam.lno.company.session")
    private let rearVideoQueue = DispatchQueue(label: "dashcam.lno.company.video.rear")
    private let frontVideoQueue = DispatchQueue(label: "dashcam.lno.company.video.front")
    private let audioQueue = DispatchQueue(label: "dashcam.lno.company.audio")

    nonisolated(unsafe) private var session: AVCaptureSession?
    nonisolated(unsafe) private var rearInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var frontInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var audioInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private let rearOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let frontOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioOutput = AVCaptureAudioDataOutput()

    /// One coordinator per camera. They report, live, the angle each connection needs in
    /// order to keep the horizon level as the phone turns in its cradle.
    private var rearRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var frontRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    private var observers: [NSObjectProtocol] = []
    private var systemPressureObservation: NSKeyValueObservation?
    private var isConfigured = false
    /// The frame rate the last build actually applied to the cameras, which is the driver's
    /// choice until the hardware budget says otherwise. Read by the budget walk.
    nonisolated(unsafe) private var appliedFrameRate = 30

    /// Latest resolved encoding parameters, read by `RecordingManager` when it starts.
    private(set) var rearFormat = VideoFormatDescriptor.resolved(for: .standard, codec: AVVideoCodecType.hevc.rawValue)
    private(set) var frontFormat = VideoFormatDescriptor.resolved(for: .standard, codec: AVVideoCodecType.hevc.rawValue)

    /// What `buildSession` produces: the status to publish plus the encoder settings the
    /// hardware actually agreed to.
    private struct BuildResult {
        var status: CaptureStatus
        var rearFormat: VideoFormatDescriptor
        var frontFormat: VideoFormatDescriptor
    }
    /// Angle currently applied to the recording connections, in degrees. Published so the
    /// UI can reason about the shape of what is being written.
    @Published private(set) var captureRotationAngle: CGFloat = 0

    init() {
        rearPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.videoGravity = .resizeAspectFill
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        rotationObservations.forEach { $0.invalidate() }
    }

    // MARK: - Lifecycle

    /// Builds (or rebuilds) the graph for the given settings and starts it.
    ///
    /// Safe to call repeatedly — a quality or front-camera change tears the graph down
    /// and reconfigures rather than trying to mutate a live multi-cam session.
    func configureAndStart(settings: RecordingSettings) async {
        #if targetEnvironment(simulator)
        status = CaptureStatus(mode: .unavailable, unavailability: .simulator)
        return
        #else
        let cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard cameraGranted else {
            status = CaptureStatus(mode: .unavailable, unavailability: .permissionDenied)
            return
        }

        let wantsFront = settings.frontCameraEnabled
        let wantsAudio = settings.recordAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let quality = settings.quality
        let lens = settings.rearLens
        let adaptiveImage = settings.adaptiveImage

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<BuildResult, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: BuildResult(
                        status: CaptureStatus(mode: .unavailable, unavailability: .noCamera),
                        rearFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue),
                        frontFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue)
                    ))
                    return
                }
                self.appliedFrameRate = quality.frameRate
                var build = self.buildSession(
                    quality: quality,
                    wantsFront: wantsFront,
                    wantsAudio: wantsAudio,
                    lens: lens,
                    adaptiveImage: adaptiveImage
                )
                // A two-camera graph that costs more than the hardware allows starts, says
                // it is running, and delivers nothing. Walk it down until it fits — and if
                // nothing fits, rebuild with one camera rather than hand back a frozen
                // picture. Cf. `MultiCamBudget`.
                if build.status.mode == .dual, !self.fitWithinHardwareBudget(quality: quality) {
                    build = self.buildSession(
                        quality: quality, wantsFront: false, wantsAudio: wantsAudio,
                        lens: lens, adaptiveImage: adaptiveImage
                    )
                }
                if let multiCam = self.session as? AVCaptureMultiCamSession {
                    build.status.hardwareCost = multiCam.hardwareCost
                    build.status.systemPressureCost = multiCam.systemPressureCost
                }
                build.rearFormat.fps = self.appliedFrameRate
                build.frontFormat.fps = self.appliedFrameRate
                continuation.resume(returning: build)
            }
        }

        status = result.status
        rearFormat = result.rearFormat
        frontFormat = result.frontFormat
        isConfigured = result.status.mode != .unavailable
        if isConfigured {
            installObservers()
            installRotationTracking()
            startRunning()
        }
        #endif
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.session, !session.isRunning else { return }
            session.startRunning()
            // Only once the session is actually running: exposure settings applied to a
            // camera that has not started yet are applied to a camera that will reset
            // them, and the attempt costs a device lock nobody needed.
            if let device = self.pendingOptimiserDevice {
                self.sceneOptimiser.start(on: device)
            }
            let startedAt = Date()
            self.startedRunningAt = startedAt
            self.startWatchdog()
            Task { @MainActor [weak self] in
                self?.status.isRunning = true
                self?.status.startedRunningAt = startedAt
            }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            self?.stopWatchdog()
            guard let session = self?.session, session.isRunning else { return }
            session.stopRunning()
            Task { @MainActor [weak self] in self?.status.isRunning = false }
        }
    }

    /// Turns audio capture on/off without rebuilding the whole graph — the audio input is
    /// the only part of the configuration a user can flip mid-drive.
    func setAudioEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            if enabled {
                guard self.audioInput == nil,
                      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      let device = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: device)
                else { return }
                self.attachAudio(input: input, to: session)
            } else if let input = self.audioInput {
                for connection in session.connections where connection.output === self.audioOutput {
                    session.removeConnection(connection)
                }
                session.removeOutput(self.audioOutput)
                session.removeInput(input)
                self.audioInput = nil
                Task { @MainActor [weak self] in self?.status.audioActive = false }
            }
        }
    }

    /// Applies a reduced quality without a full teardown, used by `ThermalManager`.
    /// Only the encoder target changes; the capture formats stay put, because switching
    /// `activeFormat` mid-recording stalls the session for hundreds of milliseconds.
    func applyDegradedQuality(_ quality: VideoQuality) {
        rearFormat = VideoFormatDescriptor.resolved(for: quality, codec: rearFormat.codec)
        frontFormat = VideoFormatDescriptor.resolved(for: quality, codec: frontFormat.codec)
    }

    // MARK: - Session construction

    /// Runs on `sessionQueue`. Returns the status to publish.
    nonisolated private func buildSession(
        quality: VideoQuality,
        wantsFront: Bool,
        wantsAudio: Bool,
        lens: RearLens = .ultraWide,
        adaptiveImage: Bool = true
    ) -> BuildResult {
        tearDown()

        guard let rearDevice = Self.preferredRearDevice(lens: lens) else {
            return BuildResult(status: CaptureStatus(mode: .unavailable, unavailability: .noCamera), rearFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue), frontFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue))
        }

        let multiCamPair = wantsFront ? Self.multiCamPair(preferring: rearDevice, lens: lens) : nil
        let useMultiCam = multiCamPair != nil && AVCaptureMultiCamSession.isMultiCamSupported

        let session: AVCaptureSession = useMultiCam ? AVCaptureMultiCamSession() : AVCaptureSession()
        self.session = session

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let effectiveRear = multiCamPair?.rear ?? rearDevice
        let codec = Self.bestAvailableCodec()
        var frontFormat = VideoFormatDescriptor.resolved(for: quality, codec: codec)

        // ---- Rear ----------------------------------------------------------
        guard let rearInput = try? AVCaptureDeviceInput(device: effectiveRear) else {
            return BuildResult(status: CaptureStatus(mode: .unavailable, unavailability: .configurationFailed("rear input")), rearFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue), frontFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue))
        }
        self.rearInput = rearInput

        let rearDimensions = Self.configureFormat(
            on: effectiveRear, quality: quality, multiCam: useMultiCam
        )
        _ = rearDimensions   // the writer sizes each segment from the frames it receives
        let rearFormat = VideoFormatDescriptor.resolved(for: quality, codec: codec)

        // The device is *not* touched here. Locking a camera for configuration inside a
        // session's own `beginConfiguration`/`commitConfiguration` block means two things
        // reconfiguring the same hardware at once, and what came back was a preview frozen
        // on its first frame. The optimiser is started once the session is running, from
        // `startRunning()`, where the camera belongs to nobody else.
        pendingOptimiserDevice = adaptiveImage ? effectiveRear : nil
        sceneOptimiser.allowsHDR = !useMultiCam
        sceneOptimiser.stop()

        rearOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        // Dropping a late frame is strictly better than letting buffers pile up until the
        // capture stalls — a dashcam values continuity over frame-perfect capture.
        rearOutput.alwaysDiscardsLateVideoFrames = true
        router.register(rearOutput, as: .rearVideo)
        rearOutput.setSampleBufferDelegate(router, queue: rearVideoQueue)

        if useMultiCam {
            session.addInputWithNoConnections(rearInput)
            session.addOutputWithNoConnections(rearOutput)
            guard let port = rearInput.ports(for: .video, sourceDeviceType: effectiveRear.deviceType, sourceDevicePosition: effectiveRear.position).first else {
                return BuildResult(status: CaptureStatus(mode: .unavailable, unavailability: .configurationFailed("rear port")), rearFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue), frontFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue))
            }
            let dataConnection = AVCaptureConnection(inputPorts: [port], output: rearOutput)
            if session.canAddConnection(dataConnection) { session.addConnection(dataConnection) }
            rearPreviewLayer.setSessionWithNoConnection(session)
            let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: rearPreviewLayer)
            if session.canAddConnection(previewConnection) { session.addConnection(previewConnection) }
        } else {
            guard session.canAddInput(rearInput), session.canAddOutput(rearOutput) else {
                return BuildResult(status: CaptureStatus(mode: .unavailable, unavailability: .configurationFailed("rear attach")), rearFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue), frontFormat: .resolved(for: quality, codec: AVVideoCodecType.h264.rawValue))
            }
            session.addInput(rearInput)
            session.addOutput(rearOutput)
            rearPreviewLayer.session = session
            // Only worth paying for outside multi-cam: stabilisation is a real slice of
            // the shared hardware budget.
            if let connection = rearOutput.connection(with: .video),
               connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
        }

        // ---- Front ---------------------------------------------------------
        var frontActive = false
        if useMultiCam, let frontDevice = multiCamPair?.front,
           let frontInput = try? AVCaptureDeviceInput(device: frontDevice) {
            self.frontInput = frontInput
            let frontDimensions = Self.configureFormat(on: frontDevice, quality: quality, multiCam: true)
            _ = frontDimensions
            frontFormat = VideoFormatDescriptor.resolved(for: quality, codec: codec)

            frontOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            frontOutput.alwaysDiscardsLateVideoFrames = true
            router.register(frontOutput, as: .frontVideo)
            frontOutput.setSampleBufferDelegate(router, queue: frontVideoQueue)

            session.addInputWithNoConnections(frontInput)
            session.addOutputWithNoConnections(frontOutput)
            if let port = frontInput.ports(for: .video, sourceDeviceType: frontDevice.deviceType, sourceDevicePosition: frontDevice.position).first {
                let dataConnection = AVCaptureConnection(inputPorts: [port], output: frontOutput)
                if session.canAddConnection(dataConnection) {
                    session.addConnection(dataConnection)
                    frontActive = true
                }
                frontPreviewLayer.setSessionWithNoConnection(session)
                let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: frontPreviewLayer)
                if session.canAddConnection(previewConnection) { session.addConnection(previewConnection) }
            }
        }

        // ---- Audio ---------------------------------------------------------
        var audioActive = false
        if wantsAudio, let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device) {
            audioActive = attachAudio(input: input, to: session)
        }

        let mode: CaptureMode = frontActive ? .dual : .rearOnly
        var newStatus = CaptureStatus(
            mode: mode,
            unavailability: nil,
            isRunning: false,
            rearActive: true,
            frontActive: frontActive,
            audioActive: audioActive,
            rearLensKey: Self.lensKey(for: effectiveRear)
        )
        if let multiCamSession = session as? AVCaptureMultiCamSession {
            newStatus.hardwareCost = multiCamSession.hardwareCost
            newStatus.systemPressureCost = multiCamSession.systemPressureCost
        }
        return BuildResult(status: newStatus, rearFormat: rearFormat, frontFormat: frontFormat)
    }

    /// Attaches the audio input/output, with manual connections when multi-cam is in play.
    /// Returns whether audio ended up connected.
    @discardableResult
    nonisolated private func attachAudio(input: AVCaptureDeviceInput, to session: AVCaptureSession) -> Bool {
        router.register(audioOutput, as: .audio)
        audioOutput.setSampleBufferDelegate(router, queue: audioQueue)

        if session is AVCaptureMultiCamSession {
            session.addInputWithNoConnections(input)
            session.addOutputWithNoConnections(audioOutput)
            guard let port = input.ports(for: .audio, sourceDeviceType: input.device.deviceType, sourceDevicePosition: .unspecified).first else { return false }
            let connection = AVCaptureConnection(inputPorts: [port], output: audioOutput)
            guard session.canAddConnection(connection) else { return false }
            session.addConnection(connection)
        } else {
            guard session.canAddInput(input), session.canAddOutput(audioOutput) else { return false }
            session.addInput(input)
            session.addOutput(audioOutput)
        }
        audioInput = input
        Task { @MainActor [weak self] in self?.status.audioActive = true }
        return true
    }

    /// Reads the scene from the rear device and steers exposure with it.
    nonisolated private let sceneOptimiser = SceneOptimiser(queue: DispatchQueue(label: "dashcam.scene", qos: .utility))
    /// The camera the optimiser will steer, once the session is running. Written on
    /// `sessionQueue` while building, read on the same queue when starting.
    nonisolated(unsafe) private var pendingOptimiserDevice: AVCaptureDevice?
    /// When the session was last told to run, and the timer that checks it kept its word.
    nonisolated(unsafe) private var startedRunningAt: Date?
    /// When a video frame last arrived, whatever the camera — the only evidence that the
    /// cameras are doing anything, as opposed to claiming to. Read by the watchdog, and by
    /// a drive checking that it is actually recording something.
    var lastVideoFrame: Date? { router.lastVideoFrame }

    nonisolated(unsafe) private var watchdogTimer: DispatchSourceTimer?
    /// How many rebuilds a stall is allowed to trigger.
    ///
    /// It used to be one, which is one too few at launch: the first build is the one most
    /// likely to be wrong — an over-budget multi-cam graph, a camera another app has not
    /// finished handing back — and a single retry that lands in the same state leaves the
    /// driver with a frozen picture and no further attempt for the life of the process.
    /// Two, and no more: a camera that freezes twice is a broken device, and looping on it
    /// would burn the battery without ever showing a picture.
    nonisolated(unsafe) private static let stallRecoveryLimit = 2
    nonisolated(unsafe) private var stallRecoveries = 0

    /// Watches for a session that says it is running and shows a still picture.
    ///
    /// `isRunning` is the session's opinion of itself; frames are the evidence. When the
    /// two disagree the app rebuilds the capture graph, because a dashcam filming its own
    /// first frame for an hour is worse than one that admits it failed.
    nonisolated private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + CaptureWatchdog.firstFrameTolerance, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let session = self.session else { return }
            let verdict = CaptureWatchdog.assess(
                isRunning: session.isRunning,
                lastFrame: self.router.lastVideoFrame,
                startedRunningAt: self.startedRunningAt
            )
            // Published every tick, whatever the verdict: the cards answer to this, and a
            // camera delivering nothing has to be able to say so long before the watchdog
            // decides to rebuild anything.
            let lastFrame = self.router.lastVideoFrame
            let startedAt = self.startedRunningAt
            Task { @MainActor [weak self] in
                self?.status.lastVideoFrame = lastFrame
                self?.status.startedRunningAt = startedAt
            }
            guard verdict == .stalled, self.stallRecoveries < Self.stallRecoveryLimit else { return }
            self.stallRecoveries += 1
            Log.capture.error("Capture stalled with no frame — rebuild \(self.stallRecoveries, privacy: .public) of \(Self.stallRecoveryLimit, privacy: .public)")
            self.stopWatchdog()
            Task { @MainActor in
                await AppEnvironment.shared?.reconfigureCapture()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    nonisolated private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    nonisolated private func tearDown() {
        stopWatchdog()
        startedRunningAt = nil
        sceneOptimiser.stop()
        pendingOptimiserDevice = nil
        if let session {
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
        rearInput = nil
        frontInput = nil
        audioInput = nil
        session = nil
    }

    // MARK: - Device selection

    /// Ultra wide first (a dashcam wants the widest field of view it can get), wide as a
    /// fallback on devices with no ultra-wide lens.
    nonisolated private static func preferredRearDevice(lens: RearLens) -> AVCaptureDevice? {
        switch lens {
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .wide:
            // No falling back to ultra-wide here: someone who asked for the readable lens
            // would rather have the wide one than the opposite of their choice.
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        }
    }

    /// Finds a back+front pair that the hardware actually supports running together.
    ///
    /// Never assumes a combination: it reads `supportedMultiCamDeviceSets` and picks the
    /// first set containing both a back and a front camera, preferring the set that also
    /// contains the ultra-wide lens.
    nonisolated private static func multiCamPair(preferring preferredRear: AVCaptureDevice, lens: RearLens = .ultraWide) -> (rear: AVCaptureDevice, front: AVCaptureDevice)? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified
        )

        var fallback: (AVCaptureDevice, AVCaptureDevice)?
        for deviceSet in discovery.supportedMultiCamDeviceSets {
            let backs = deviceSet.filter { $0.position == .back }
            let fronts = deviceSet.filter { $0.position == .front }
            guard let front = fronts.first, !backs.isEmpty else { continue }

            if let exact = backs.first(where: { $0.uniqueID == preferredRear.uniqueID }) {
                return (exact, front)
            }
            // Second choice is the lens the driver asked for, in whatever set offers it.
            let wanted: AVCaptureDevice.DeviceType = lens == .wide ? .builtInWideAngleCamera : .builtInUltraWideCamera
            if let match = backs.first(where: { $0.deviceType == wanted }) {
                return (match, front)
            }
            if fallback == nil, let anyBack = backs.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? backs.first {
                fallback = (anyBack, front)
            }
        }
        return fallback.map { (rear: $0.0, front: $0.1) }
    }

    /// Picks the narrowest format that still covers the target resolution, is multi-cam
    /// capable when it needs to be, and can sustain the target frame rate. Returns the
    /// dimensions that were actually locked in.
    @discardableResult
    nonisolated private static func configureFormat(
        on device: AVCaptureDevice, quality: VideoQuality, multiCam: Bool, frameRate: Int? = nil
    ) -> (width: Int, height: Int) {
        let target = quality.dimensions
        let requestedRate = frameRate ?? quality.frameRate
        let fps = Double(requestedRate)

        let candidates = device.formats.filter { format in
            if multiCam && !format.isMultiCamSupported { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= target.width, dims.height >= target.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }
        }

        // Rank by "closest to 16:9 first, then smallest". Aspect ratio leads because a
        // 4:3 sensor format encoded into a 16:9 box comes out visibly squashed, whereas
        // an oversized 16:9 format merely costs a little bandwidth before downscaling.
        func rank(_ format: AVCaptureDevice.Format) -> (Double, Int) {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let aspect = Double(dims.width) / Double(max(1, dims.height))
            return (abs(aspect - 16.0 / 9.0), Int(dims.width) * Int(dims.height))
        }
        let chosen = candidates.min { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            return l.0 == r.0 ? l.1 < r.1 : l.0 < r.0
        }

        guard let format = chosen else {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return (Int(dims.width), Int(dims.height))
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(requestedRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch {
            Log.capture.error("Could not lock \(device.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (Int(dims.width), Int(dims.height))
    }

    /// HEVC when the encoder will take it, H.264 otherwise. Asked, never assumed —
    /// `canApply` is the only honest way to know before the writer is running.
    nonisolated private static func bestAvailableCodec() -> String {
        let hevc: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]
        // `canApply` is an instance method, so a throwaway writer is the only way to ask
        // the question before a real one exists. The file is never written to.
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent("codec-probe.mov")
        try? FileManager.default.removeItem(at: probeURL)
        defer { try? FileManager.default.removeItem(at: probeURL) }

        guard let probe = try? AVAssetWriter(outputURL: probeURL, fileType: .mov) else {
            return AVVideoCodecType.h264.rawValue
        }
        return probe.canApply(outputSettings: hevc, forMediaType: .video)
            ? AVVideoCodecType.hevc.rawValue
            : AVVideoCodecType.h264.rawValue
    }

    nonisolated private static func lensKey(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "lens.ultrawide"
        case .builtInWideAngleCamera: return "lens.wide"
        case .builtInTelephotoCamera: return "lens.telephoto"
        default: return "lens.unknown"
        }
    }

    // MARK: - Rotation

    /// Tracks the phone's attitude and keeps both the previews and the recording level.
    ///
    /// `AVCaptureDevice.RotationCoordinator` is the supported way to do this: it accounts
    /// for the device's physical orientation *and* for how the preview layer is laid out,
    /// which a raw `UIDevice.orientation` reading does not. Two angles come out of it and
    /// they are not interchangeable — the preview one keeps the on-screen image upright,
    /// the capture one keeps the recorded frames upright.
    ///
    /// The rotation is applied to the capture connection rather than baked into the
    /// writer as a transform. That costs a hardware-accelerated rotate per frame, and buys
    /// something a transform cannot: turning the phone mid-drive changes the recording
    /// immediately, instead of being frozen at whatever angle it had when Start was
    /// pressed.
    private func installRotationTracking() {
        rotationObservations.forEach { $0.invalidate() }
        rotationObservations.removeAll()

        if let rearDevice = rearInput?.device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: rearDevice, previewLayer: rearPreviewLayer)
            rearRotationCoordinator = coordinator
            observe(coordinator, camera: .rear)
        }
        if let frontDevice = frontInput?.device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: frontDevice, previewLayer: frontPreviewLayer)
            frontRotationCoordinator = coordinator
            observe(coordinator, camera: .front)
        }
    }

    private func observe(_ coordinator: AVCaptureDevice.RotationCoordinator, camera: CameraPosition) {
        rotationObservations.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor [weak self] in self?.applyPreviewRotation(angle, camera: camera) }
            }
        )
        rotationObservations.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                Task { @MainActor [weak self] in self?.applyCaptureRotation(angle, camera: camera) }
            }
        )
    }

    private func applyPreviewRotation(_ angle: CGFloat, camera: CameraPosition) {
        let layer = camera == .rear ? rearPreviewLayer : frontPreviewLayer
        guard let connection = layer.connection,
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        // No implicit animation: a preview layer that animates its rotation shows a
        // visibly smeared frame every time the phone turns.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        connection.videoRotationAngle = angle
        CATransaction.commit()
    }

    private func applyCaptureRotation(_ angle: CGFloat, camera: CameraPosition) {
        let output: AVCaptureOutput = camera == .rear ? rearOutput : frontOutput
        sessionQueue.async {
            guard let connection = output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle)
            else { return }
            connection.videoRotationAngle = angle
        }
        if camera == .rear { captureRotationAngle = angle }
    }

    // MARK: - Hardware budget

    /// Walks the configuration down until `hardwareCost` fits, and says whether the cabin
    /// camera had to go.
    ///
    /// Runs on `sessionQueue`, after the graph is built and before it is started —
    /// `hardwareCost` is only meaningful once the connections exist, and a session started
    /// over budget is a session that delivers nothing.
    nonisolated private func fitWithinHardwareBudget(quality: VideoQuality) -> Bool {
        guard let session = session as? AVCaptureMultiCamSession else { return true }

        var rate = appliedFrameRate
        // Bounded: the ladder is four rungs, and a loop around a live capture graph is not
        // somewhere to discover an off-by-one.
        for _ in 0..<MultiCamBudget.frameRateLadder.count {
            let cost = session.hardwareCost
            switch MultiCamBudget.nextStep(cost: cost, currentFrameRate: rate) {
            case .accept:
                if rate != appliedFrameRate {
                    Log.capture.info("Multi-cam cost \(cost, privacy: .public) — settled at \(rate, privacy: .public) fps")
                }
                appliedFrameRate = rate
                return true
            case .lowerFrameRate(let next):
                Log.capture.info("Multi-cam cost \(cost, privacy: .public) over budget — trying \(next, privacy: .public) fps")
                rate = next
                // ⚠️ Frame durations only, and **outside** any `beginConfiguration`.
                //
                // The first version of this walked the whole format selection again inside
                // the session's own configuration block — which is exactly what the comment
                // in `buildSession` warns against, and for exactly the reason it gives:
                // locking a camera for configuration while the session is reconfiguring the
                // same hardware leaves a preview frozen on its first frame. It shipped, and
                // it came back as « the cameras do not start, it stays black » with every
                // status reading Ready. A frame duration needs no session reconfiguration,
                // and it is the only lever this walk actually needs.
                for device in [rearInput?.device, frontInput?.device].compactMap({ $0 }) {
                    Self.applyFrameRate(next, to: device)
                }
            case .dropCabinCamera:
                Log.capture.error("Multi-cam cost \(cost, privacy: .public) over budget at every frame rate — one camera")
                return false
            }
        }
        return MultiCamBudget.fits(session.hardwareCost)
    }

    /// The one change the budget walk makes to a built graph. Deliberately narrow: the
    /// active *format* cannot be changed without `beginConfiguration`, a frame duration can.
    nonisolated private static func applyFrameRate(_ fps: Int, to device: AVCaptureDevice) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        // A format has a floor and a ceiling on what it will accept; asking outside it is
        // an exception thrown at the camera, not a slower camera.
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
        }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    // MARK: - Observers

    private func installObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            Task { @MainActor in
                self?.status.interruption = reason.map(CaptureInterruption.init(reason:)) ?? .unknown
                self?.status.isRunning = false
            }
        })

        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.status.interruption = nil
                // AVFoundation restarts the session itself once the interruption clears;
                // nudging it is harmless and covers the cases where it does not.
                self?.startRunning()
            }
        })

        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Log.capture.error("Runtime error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            Task { @MainActor in
                guard let self else { return }
                // .mediaServicesWereReset is recoverable by simply starting again.
                if error?.code == .mediaServicesWereReset {
                    self.startRunning()
                } else {
                    self.status.interruption = .unknown
                    self.status.isRunning = false
                }
            }
        })

        if let multiCamSession = session as? AVCaptureMultiCamSession {
            systemPressureObservation = multiCamSession.observe(\.systemPressureCost, options: [.new]) { [weak self] session, _ in
                let cost = session.systemPressureCost
                let hardware = session.hardwareCost
                Task { @MainActor in
                    self?.status.systemPressureCost = cost
                    self?.status.hardwareCost = hardware
                }
            }
        }
    }
}

// MARK: - Sample buffer delivery

/// Non-isolated delegate for the three data outputs.
///
/// The capture queues must not touch main-actor state, so routing lives in its own tiny
/// object: it maps an output back to its `SampleSource` by identity and hands the buffer
/// to the sink. Nothing else.
final class SampleRouter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var sink: SampleSink?

    /// When a video frame last arrived, whatever the camera. Read by the watchdog, which
    /// is the only thing that can tell a frozen preview from a working one.
    private var _lastVideoFrame: Date?
    /// Read from the main actor as well as from the watchdog's queue, so it goes through
    /// the same lock as the write.
    var lastVideoFrame: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastVideoFrame
    }

    private var sources: [ObjectIdentifier: SampleSource] = [:]
    private let lock = NSLock()

    func register(_ output: AVCaptureOutput, as source: SampleSource) {
        lock.lock()
        sources[ObjectIdentifier(output)] = source
        lock.unlock()
    }

    private func source(for output: AVCaptureOutput) -> SampleSource? {
        lock.lock()
        defer { lock.unlock() }
        return sources[ObjectIdentifier(output)]
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let source = source(for: output) else { return }
        if source != .audio {
            lock.lock()
            _lastVideoFrame = Date()
            lock.unlock()
        }
        sink?.consume(sampleBuffer, from: source)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let source = source(for: output) else { return }
        sink?.handleDroppedSample(from: source)
    }
}
