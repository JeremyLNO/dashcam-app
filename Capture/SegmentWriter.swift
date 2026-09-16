import AVFoundation
import CoreLocation
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
/// 3. **The frame is always landscape.** Rotating the phone changes the shape of the
///    frames the capture connection delivers, but not the shape of the file: the encoder
///    fits whatever arrives into a fixed 16:9 box, pillarboxing an upright image rather
///    than stretching or cropping it. That keeps every segment of a drive the same size,
///    which is what lets them concatenate and composite without a compositor.
final class SegmentWriter {
    let camera: CameraPosition

    private let sessionID: UUID
    private let format: VideoFormatDescriptor
    private let includesAudio: Bool
    private let segmentDuration: TimeInterval
    private let onSegmentFinished: @Sendable (FinishedSegment) -> Void
    private let onFailure: @Sendable (Error) -> Void

    private let queue: DispatchQueue

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// The timed track: where the car was, second by second, inside the file itself.
    private var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
    /// The last position and acceleration handed over, written into the head of the next
    /// segment so a file opened alone still says where it starts.
    private var latestLocation: CLLocation?
    private var latestGForce: Double?

    /// Whether the microphone is ours right now. Starts true — a writer built with audio
    /// was built because audio was available.
    private var isAudioAvailable = true

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
        segmentDuration: TimeInterval,
        onSegmentFinished: @escaping @Sendable (FinishedSegment) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.camera = camera
        self.sessionID = sessionID
        self.format = format
        self.includesAudio = includesAudio
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

    /// Told when another app takes the microphone, and when it gives it back.
    ///
    /// Read at the top of each segment rather than acted on immediately: the segment being
    /// written keeps the audio track it already has — which simply ends early, and that is
    /// honest — while the **next** one is opened without an audio input at all. An input
    /// declared and never fed is the defect that produces a movie a fraction of its length,
    /// or one that will not open. Cf. the metadata track below, same lesson.
    func setAudioAvailable(_ available: Bool) {
        queue.async { [weak self] in self?.isAudioAvailable = available }
    }

    /// Hands over where the car is, to be written into the timed track.
    ///
    /// Called from the location and motion paths, a couple of times a second at most. It
    /// never blocks them: the sample is stamped with the most recent video timestamp, so
    /// a position always lands on footage that exists rather than on a moment the file
    /// has not reached.
    func appendMetadata(location: CLLocation?, gForce: Double?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let location { self.latestLocation = location }
            if let gForce { self.latestGForce = gForce }
            self.writeTimedMetadata(location: location, gForce: gForce)
        }
    }

    /// Closes the current segment and calls back once everything is on disk.
    ///
    /// `self` is captured **strongly** here, deliberately. A weak capture let the writer be
    /// deallocated between `stop()` being called and its block reaching the front of the
    /// queue, and the block then did nothing: the `.mov` had been created by
    /// `startWriting()` but was never finalized, and `onSegmentFinished` never fired. The
    /// footage was on disk and the database never learned it existed — which looks exactly
    /// like a camera that did not record. A writer has to outlive its own finalization.
    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async {
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
            // triggered the cut becomes the first frame of the new segment, so the
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

    /// Builds the metadata input, or returns nil and lets the segment be written without
    /// one. Nothing here is allowed to cost a recording.
    private static func makeMetadataAdaptor(for writer: AVAssetWriter) -> AVAssetWriterInputMetadataAdaptor? {
        var formatDescription: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: SegmentMetadata.timedSpecifications as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return nil }

        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    /// Appends one group of timed items at the latest video timestamp.
    private func writeTimedMetadata(location: CLLocation?, gForce: Double?) {
        guard let writer, writer.status == .writing,
              let adaptor = metadataAdaptor, adaptor.assetWriterInput.isReadyForMoreMediaData,
              lastPTS.isValid, CMTimeCompare(lastPTS, segmentStartPTS) >= 0
        else { return }

        let items = SegmentMetadata.timedItems(location: location, gForce: gForce)
        guard !items.isEmpty else { return }

        // A duration of zero would be dropped by some readers; a second matches the rate
        // these samples arrive at and keeps the track continuous enough to scrub.
        let group = AVTimedMetadataGroup(
            items: items,
            timeRange: CMTimeRange(start: lastPTS, duration: CMTime(seconds: 1, preferredTimescale: 600))
        )
        adaptor.append(group)
    }

    private func appendToVideoInput(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData
        else { return }
        videoInput.append(sampleBuffer)
    }

    private func startSegment(index: Int, at pts: CMTime) {
        let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: index)
        // The session folder does not exist until something makes it, and AVAssetWriter
        // does not create intermediate directories — it simply fails to open the file.
        let url = StorageLocations.prepareURL(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: url)

        do {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Lets AVFoundation write a recoverable movie header as it goes, so a file
            // killed mid-segment is often still salvageable by RecoveryManager.
            newWriter.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            newWriter.shouldOptimizeForNetworkUse = false
            // What the file says about itself, readable by anything that opens a .mov —
            // an insurer's expert included, who will never have heard of this app.
            newWriter.metadata = SegmentMetadata.fileLevel(
                sessionID: sessionID,
                camera: camera,
                segmentIndex: index,
                startedAt: wallClock(for: pts),
                location: latestLocation
            )

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
            videoInput.expectsMediaDataInRealTime = true
            // No transform: the capture connection already rotates the frames to keep the
            // horizon level, so what arrives here is what should be played back.
            guard newWriter.canAdd(videoInput) else {
                throw NSError(domain: "Dashcam.SegmentWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "video input rejected"])
            }
            newWriter.add(videoInput)
            self.videoInput = videoInput

            if includesAudio && isAudioAvailable {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if newWriter.canAdd(audioInput) {
                    newWriter.add(audioInput)
                    self.audioInput = audioInput
                }
            } else {
                self.audioInput = nil
            }

            // The timed track is added **only when there is something to put in it**.
            // An input that is declared and never fed does not produce an empty track: it
            // produces a movie a third of its true length, and sometimes one that will not
            // open at all. Two tests that read the written file caught it; nothing in the
            // writing path complained.
            //
            // It is also the honest behaviour: a drive recorded without location has no
            // positions to carry, and an empty track claiming otherwise helps nobody.
            metadataAdaptor = (latestLocation != nil || latestGForce != nil)
                ? Self.makeMetadataAdaptor(for: newWriter)
                : nil

            guard newWriter.startWriting() else {
                throw newWriter.error ?? NSError(
                    domain: "Dashcam.SegmentWriter", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "startWriting refused for \(url.path)"]
                )
            }
            newWriter.startSession(atSourceTime: pts)

            writer = newWriter
            currentIndex = index
            currentRelativePath = relativePath
            segmentStartPTS = pts
            currentStartDate = wallClock(for: pts)
            lastPTS = pts
            // The first sample of the new segment carries what is already known, so a
            // file opened on its own starts with a position rather than waiting for the
            // next fix to arrive.
            writeTimedMetadata(location: latestLocation, gForce: latestGForce)
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

        let metadataInput = metadataAdaptor?.assetWriterInput

        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.metadataAdaptor = nil

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        metadataInput?.markAsFinished()

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
                width: format.outputWidth,
                height: format.outputHeight,
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
            AVVideoWidthKey: format.outputWidth,
            AVVideoHeightKey: format.outputHeight,
            // Fill the landscape box, cropping rather than letterboxing.
            //
            // `ResizeAspect` also produces a 1280×720 file from an upright source — but
            // the picture inside it is a narrow strip between black bars, which is not a
            // landscape video by any useful definition, and shrinks to an invisible sliver
            // once it is composited into the cabin inset. Filling crops the top and bottom
            // of the upright image instead, and on a dashcam the band that survives is the
            // road.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
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
