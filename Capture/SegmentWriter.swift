import AVFoundation
import Foundation

/// A finalized chunk of footage, handed back to `RecordingManager` so it can be indexed.
struct FinishedSegment: Sendable {
    let camera: CameraPosition
    let index: Int
    let startDate: Date
    let endDate: Date
    let relativePath: String
    let fileSize: Int64
    let width: Int
    let height: Int
    let fps: Int
    let codec: String
    let succeeded: Bool
}

/// Writes one camera's stream to disk as a series of self-contained `.mov` files.
///
/// Two properties are worth spelling out, because the whole resilience story rests on
/// them:
///
/// 1. **Every segment is finalized on its own.** A crash or a yanked power cable costs
///    at most the segment currently being written; everything before it is already a
///    complete, playable movie with its moov atom in place.
/// 2. **Segment boundaries are computed, not negotiated.** Both the front and the rear
///    writer derive the boundary from the same `(firstPTS, segmentDuration)` arithmetic,
///    so segment *n* on one camera covers the same wall-clock window as segment *n* on
///    the other — without the two writers ever talking to each other or sharing a lock.
final class SegmentWriter {
    let camera: CameraPosition

    private let sessionID: UUID
    private let format: VideoFormatDescriptor
    private let includesAudio: Bool
    private let rotationAngle: CGFloat
    private let segmentDuration: TimeInterval
    private let onSegmentFinished: @Sendable (FinishedSegment) -> Void
    private let onFailure: @Sendable (Error) -> Void

    private let queue: DispatchQueue

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var currentIndex = 0
    private var currentStartDate = Date()
    private var currentRelativePath = ""
    private var firstPTS: CMTime?
    private var firstSampleDate = Date()
    private var lastPTS: CMTime = .zero
    private var isStopping = false

    /// Finalizations in flight. `stop()` waits on this so a caller can trust that when
    /// the completion fires, every file on disk is closed.
    private let pendingFinalizations = DispatchGroup()

    init(
        camera: CameraPosition,
        sessionID: UUID,
        format: VideoFormatDescriptor,
        includesAudio: Bool,
        rotationAngle: CGFloat,
        segmentDuration: TimeInterval,
        onSegmentFinished: @escaping @Sendable (FinishedSegment) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.camera = camera
        self.sessionID = sessionID
        self.format = format
        self.includesAudio = includesAudio
        self.rotationAngle = rotationAngle
        self.segmentDuration = segmentDuration
        self.onSegmentFinished = onSegmentFinished
        self.onFailure = onFailure
        self.queue = DispatchQueue(label: "dashcam.lno.company.writer.\(camera.rawValue)")
    }

    // MARK: - Input

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.handleVideo(sampleBuffer) }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard includesAudio else { return }
        queue.async { [weak self] in self?.handleAudio(sampleBuffer) }
    }

    /// Closes the current segment and calls back once everything is on disk.
    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(); return }
            self.isStopping = true
            self.finalizeCurrentSegment(endingAt: self.lastPTS)
            self.pendingFinalizations.notify(queue: self.queue) { completion() }
        }
    }

    // MARK: - Writer plumbing

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopping, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if firstPTS == nil {
            firstPTS = pts
            firstSampleDate = Date()
            startSegment(index: 0, at: pts)
        }

        guard let firstPTS else { return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS))
        let targetIndex = max(0, Int(floor(elapsed / segmentDuration)))

        if targetIndex != currentIndex {
            // Close the old file and open the new one in the same breath: the sample that
            // triggered the rotation becomes the first frame of the new segment, so the
            // boundary costs zero frames.
            finalizeCurrentSegment(endingAt: pts)
            startSegment(index: targetIndex, at: pts)
        }

        lastPTS = pts
        appendToVideoInput(sampleBuffer)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopping, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        // Audio that arrives before the first video frame has no segment to belong to.
        guard let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, CMTimeCompare(pts, segmentStartPTS) >= 0 else { return }
        audioInput.append(sampleBuffer)
    }

    private var segmentStartPTS: CMTime = .zero

    private func appendToVideoInput(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData
        else { return }
        videoInput.append(sampleBuffer)
    }

    private func startSegment(index: Int, at pts: CMTime) {
        let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: index)
        let url = StorageLocations.absoluteURL(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: url)

        do {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Lets AVFoundation write a recoverable movie header as it goes, so a file
            // killed mid-segment is often still salvageable by RecoveryManager.
            newWriter.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            newWriter.shouldOptimizeForNetworkUse = false

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
            videoInput.expectsMediaDataInRealTime = true
            // A transform, not a pixel rotation: rotating frames would cost a full extra
            // pass over every frame for something a player does for free.
            videoInput.transform = CGAffineTransform(rotationAngle: rotationAngle * .pi / 180)
            guard newWriter.canAdd(videoInput) else {
                throw NSError(domain: "Dashcam.SegmentWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "video input rejected"])
            }
            newWriter.add(videoInput)
            self.videoInput = videoInput

            if includesAudio {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if newWriter.canAdd(audioInput) {
                    newWriter.add(audioInput)
                    self.audioInput = audioInput
                }
            } else {
                self.audioInput = nil
            }

            guard newWriter.startWriting() else {
                throw newWriter.error ?? NSError(domain: "Dashcam.SegmentWriter", code: 2)
            }
            newWriter.startSession(atSourceTime: pts)

            writer = newWriter
            currentIndex = index
            currentRelativePath = relativePath
            segmentStartPTS = pts
            currentStartDate = wallClock(for: pts)
        } catch {
            Log.recording.error("Failed to open segment \(index) for \(self.camera.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            writer = nil
            videoInput = nil
            audioInput = nil
            onFailure(error)
        }
    }

    private func finalizeCurrentSegment(endingAt pts: CMTime) {
        guard let writer, let videoInput else { return }
        let index = currentIndex
        let relativePath = currentRelativePath
        let startDate = currentStartDate
        let endDate = wallClock(for: pts)
        let format = self.format
        let camera = self.camera
        let onSegmentFinished = self.onSegmentFinished

        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        guard writer.status == .writing else {
            // Nothing usable was written; leave no zero-byte file behind.
            try? FileManager.default.removeItem(at: StorageLocations.absoluteURL(forRelativePath: relativePath))
            return
        }

        writer.endSession(atSourceTime: pts)
        pendingFinalizations.enter()
        writer.finishWriting { [pendingFinalizations] in
            let url = StorageLocations.absoluteURL(forRelativePath: relativePath)
            let succeeded = writer.status == .completed
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            if !succeeded {
                try? FileManager.default.removeItem(at: url)
            }

            onSegmentFinished(FinishedSegment(
                camera: camera,
                index: index,
                startDate: startDate,
                endDate: max(endDate, startDate),
                relativePath: relativePath,
                fileSize: size,
                width: format.width,
                height: format.height,
                fps: format.fps,
                codec: format.codec,
                succeeded: succeeded
            ))
            pendingFinalizations.leave()
        }
    }

    /// Maps a capture timestamp onto wall-clock time, anchored on the first sample. The
    /// capture clock is monotonic and unrelated to `Date()`, so a per-sample `Date()`
    /// would drift against the footage.
    private func wallClock(for pts: CMTime) -> Date {
        guard let firstPTS, pts.isValid else { return firstSampleDate }
        return firstSampleDate.addingTimeInterval(CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS)))
    }

    private func videoSettings() -> [String: Any] {
        [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: format.width,
            AVVideoHeightKey: format.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: format.bitrate,
                AVVideoExpectedSourceFrameRateKey: format.fps,
                // One keyframe per second. Denser than a delivery encode on purpose:
                // scrubbing to the instant of an incident is the whole point of the file.
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            ],
        ]
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: 64_000,
    ]
}
