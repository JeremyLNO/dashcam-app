import AVFoundation
import Foundation

/// Routes sample buffers into the per-camera segment writers.
///
/// Lives entirely off the main actor: `consume` is called on AVFoundation's capture
/// queues at 30 Hz per camera, and hopping to the main actor for each frame would be both
/// pointless and ruinous. All state changes go through one lock; the actual writing
/// happens on each `SegmentWriter`'s own queue.
final class RecordingEngine: SampleSink, @unchecked Sendable {
    struct Configuration: Sendable {
        let sessionID: UUID
        let rearFormat: VideoFormatDescriptor
        let frontFormat: VideoFormatDescriptor
        let includesFront: Bool
        let includesAudio: Bool
        let rotationAngle: CGFloat
        let segmentDuration: TimeInterval
    }

    /// `(segment, sessionID)`. Called from a writer's queue.
    var onSegmentFinished: (@Sendable (FinishedSegment, UUID) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var rearWriter: SegmentWriter?
    private var frontWriter: SegmentWriter?
    private var sessionID: UUID?
    private var droppedFrames = 0

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionID != nil
    }

    var droppedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedFrames
    }

    func start(_ configuration: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        guard sessionID == nil else { return }

        sessionID = configuration.sessionID
        droppedFrames = 0

        let id = configuration.sessionID
        let finished = onSegmentFinished
        let failed = onFailure

        rearWriter = SegmentWriter(
            camera: .rear,
            sessionID: id,
            format: configuration.rearFormat,
            includesAudio: configuration.includesAudio,
            rotationAngle: configuration.rotationAngle,
            segmentDuration: configuration.segmentDuration,
            onSegmentFinished: { segment in finished?(segment, id) },
            onFailure: { error in failed?(error) }
        )

        if configuration.includesFront {
            frontWriter = SegmentWriter(
                camera: .front,
                sessionID: id,
                format: configuration.frontFormat,
                // Audio rides with the road camera only: one microphone, one copy.
                includesAudio: false,
                rotationAngle: configuration.rotationAngle,
                segmentDuration: configuration.segmentDuration,
                onSegmentFinished: { segment in finished?(segment, id) },
                onFailure: { error in failed?(error) }
            )
        }
    }

    /// Stops the cabin camera without touching the road camera — what `ThermalManager`
    /// asks for when the device is too hot to keep both.
    func dropFrontCamera() {
        lock.lock()
        let writer = frontWriter
        frontWriter = nil
        lock.unlock()
        writer?.stop {}
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        let rear = rearWriter
        let front = frontWriter
        rearWriter = nil
        frontWriter = nil
        sessionID = nil
        lock.unlock()

        guard rear != nil || front != nil else { completion(); return }

        let group = DispatchGroup()
        if let rear { group.enter(); rear.stop { group.leave() } }
        if let front { group.enter(); front.stop { group.leave() } }
        group.notify(queue: .global(qos: .utility)) { completion() }
    }

    // MARK: - SampleSink

    func consume(_ sampleBuffer: CMSampleBuffer, from source: SampleSource) {
        lock.lock()
        let rear = rearWriter
        let front = frontWriter
        lock.unlock()

        switch source {
        case .rearVideo: rear?.appendVideo(sampleBuffer)
        case .frontVideo: front?.appendVideo(sampleBuffer)
        case .audio: rear?.appendAudio(sampleBuffer)
        }
    }

    func handleDroppedSample(from source: SampleSource) {
        lock.lock()
        droppedFrames += 1
        lock.unlock()
    }
}
