import AVFoundation
import Foundation

/// A composition plus everything needed to play or export it.
struct BuiltComposition {
    let composition: AVMutableComposition
    /// Non-nil whenever the frames need laying out (picture-in-picture, an overlay, or a
    /// drive whose geometry changed part-way through).
    let videoComposition: AVMutableVideoComposition?
    let duration: CMTime
    let renderSize: CGSize
    /// Wall-clock time of the first frame, used to line the overlay stamps up.
    let startDate: Date
    let frameRate: Int
    /// True when the phone was turned mid-drive, so the segments are not all the same
    /// shape. Such a drive cannot be exported by passthrough — the frames have to be
    /// composited into one consistent frame size.
    let hasMixedGeometry: Bool
}

/// Stitches a session's segments back into a continuous timeline.
///
/// Shared deliberately between playback and export: the two-up player the user reviews
/// footage in is the *same* composition the export writes out, so what they scrub through
/// is exactly what they will send to an insurer.
enum SessionComposition {
    enum BuildError: Error { case noFootage, trackCreationFailed }

    /// A window inside a drive, in seconds from the first frame.
    ///
    /// Trimming happens while the composition is *built*, not afterwards with
    /// `AVAssetExportSession.timeRange`. The difference matters: the overlay stamps are
    /// scheduled against the composition's own timeline, so trimming after the fact would
    /// leave every burned-in timestamp pointing at the wrong moment.
    struct ClipRange: Equatable, Sendable {
        var start: TimeInterval
        var duration: TimeInterval

        var end: TimeInterval { start + duration }

        /// Where this clip sits relative to the whole drive, used to offset the overlay.
        func offsetStartDate(from sessionStart: Date) -> Date {
            sessionStart.addingTimeInterval(start)
        }
    }

    /// One piece of footage on the timeline, with the shape it was recorded at.
    ///
    /// Turning the phone in its cradle makes the writer cut a new segment at a new size,
    /// so a single drive can hold both landscape and portrait footage. Each slice carries
    /// its own geometry rather than the composition assuming one for the whole drive.
    private struct Placement {
        var range: CMTimeRange
        var naturalSize: CGSize
        var transform: CGAffineTransform
    }

    // MARK: - Single camera

    /// One camera, concatenated in segment order.
    static func single(segments: [VideoSegment], includeAudio: Bool, clip: ClipRange? = nil) async throws -> BuiltComposition {
        let built = try await assemble(segments: segments, includeAudio: includeAudio, clip: clip)
        return BuiltComposition(
            composition: built.composition,
            videoComposition: nil,
            duration: built.duration,
            renderSize: built.renderSize,
            startDate: built.startDate,
            frameRate: built.frameRate,
            hasMixedGeometry: built.hasMixedGeometry
        )
    }

    /// Same as `single`, but with an explicit video composition so an overlay can be
    /// attached (Core Animation needs a video composition to hang off) and so a drive with
    /// mixed geometry renders into one consistent frame.
    static func singleWithLayout(segments: [VideoSegment], includeAudio: Bool, clip: ClipRange? = nil) async throws -> BuiltComposition {
        let built = try await assemble(segments: segments, includeAudio: includeAudio, clip: clip)
        guard let track = built.composition.tracks(withMediaType: .video).first else {
            return try await single(segments: segments, includeAudio: includeAudio, clip: clip)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = built.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(built.frameRate))
        videoComposition.instructions = built.placements.map { placement in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = placement.range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(
                fittingTransform(
                    naturalSize: placement.naturalSize,
                    preferred: placement.transform,
                    into: CGRect(origin: .zero, size: built.renderSize)
                ),
                at: placement.range.start
            )
            instruction.layerInstructions = [layer]
            return instruction
        }

        return BuiltComposition(
            composition: built.composition,
            videoComposition: videoComposition,
            duration: built.duration,
            renderSize: built.renderSize,
            startDate: built.startDate,
            frameRate: built.frameRate,
            hasMixedGeometry: built.hasMixedGeometry
        )
    }

    // MARK: - Picture in picture

    /// Road full-frame, cabin inset top-right.
    ///
    /// The cabin timeline is clamped to the road timeline: the inset must never outlive
    /// the footage it sits on, which is what would happen on a drive where the cabin
    /// camera kept running after the road camera was shed for heat.
    static func pictureInPicture(rear: [VideoSegment], front: [VideoSegment], includeAudio: Bool) async throws -> BuiltComposition {
        guard !rear.isEmpty, !front.isEmpty else { throw BuildError.noFootage }

        let composition = AVMutableComposition()
        guard let rearTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let frontTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.trackCreationFailed }
        let audioTrack = includeAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var rearPlacements: [Placement] = []
        var rearCursor = CMTime.zero

        for segment in rear {
            let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try rearTrack.insertTimeRange(range, of: track, at: rearCursor)
            rearPlacements.append(Placement(
                range: CMTimeRange(start: rearCursor, duration: duration),
                naturalSize: (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080),
                transform: (try? await track.load(.preferredTransform)) ?? .identity
            ))
            if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: rearCursor)
            }
            rearCursor = CMTimeAdd(rearCursor, duration)
        }
        guard rearCursor.seconds > 0 else { throw BuildError.noFootage }

        var frontPlacements: [Placement] = []
        var frontCursor = CMTime.zero

        for segment in front {
            let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            let remaining = CMTimeSubtract(rearCursor, frontCursor)
            guard remaining.seconds > 0 else { break }
            let used = CMTimeMinimum(duration, remaining)
            try frontTrack.insertTimeRange(CMTimeRange(start: .zero, duration: used), of: track, at: frontCursor)
            frontPlacements.append(Placement(
                range: CMTimeRange(start: frontCursor, duration: used),
                naturalSize: (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080),
                transform: (try? await track.load(.preferredTransform)) ?? .identity
            ))
            frontCursor = CMTimeAdd(frontCursor, used)
        }

        let renderSize = dominantRenderSize(of: rearPlacements)
        let fps = rear.first?.fps ?? 30

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        // Top-right, matching where the live recording screen puts the cabin preview —
        // playback that moves it elsewhere reads as a different app.
        //
        // The y here is measured from the TOP. A video composition's layer-instruction
        // transforms live in a top-left origin space, not the bottom-left one Core
        // Graphics uses everywhere else in this file. Getting that backwards is what put
        // the cabin inset in the bottom-right corner, and only rendering a frame and
        // looking at the pixels revealed it — every geometry assertion passed happily.
        let margin = renderSize.width * 0.025
        let insetWidth = renderSize.width * 0.28
        let insetHeight = insetWidth * (renderSize.height / max(1, renderSize.width))
        let insetRect = CGRect(
            x: renderSize.width - insetWidth - margin,
            y: margin,
            width: insetWidth,
            height: insetHeight
        )

        // Split the timeline wherever either camera changed shape, so every slice gets
        // transforms computed from the geometry that is actually on screen during it.
        videoComposition.instructions = slices(of: [rearPlacements, frontPlacements], upTo: rearCursor).map { slice in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = slice
            var layers: [AVMutableVideoCompositionLayerInstruction] = []

            if let frontPlacement = placement(at: slice.start, in: frontPlacements) {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontTrack)
                layer.setTransform(
                    fittingTransform(naturalSize: frontPlacement.naturalSize, preferred: frontPlacement.transform, into: insetRect),
                    at: slice.start
                )
                layers.append(layer)
            }
            if let rearPlacement = placement(at: slice.start, in: rearPlacements) {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: rearTrack)
                layer.setTransform(
                    fittingTransform(
                        naturalSize: rearPlacement.naturalSize,
                        preferred: rearPlacement.transform,
                        into: CGRect(origin: .zero, size: renderSize)
                    ),
                    at: slice.start
                )
                layers.append(layer)
            }
            // Array order is front-to-back, so the cabin inset has to come first to sit
            // on top of the road.
            instruction.layerInstructions = layers
            return instruction
        }

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            duration: rearCursor,
            renderSize: renderSize,
            startDate: rear[0].startDate,
            frameRate: fps,
            hasMixedGeometry: isMixed(rearPlacements) || isMixed(frontPlacements)
        )
    }

    // MARK: - Assembly

    private struct Assembled {
        var composition: AVMutableComposition
        var placements: [Placement]
        var duration: CMTime
        var renderSize: CGSize
        var startDate: Date
        var frameRate: Int
        var hasMixedGeometry: Bool
    }

    private static func assemble(segments: [VideoSegment], includeAudio: Bool, clip: ClipRange? = nil) async throws -> Assembled {
        guard !segments.isEmpty else { throw BuildError.noFootage }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.trackCreationFailed
        }
        let audioTrack = includeAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var placements: [Placement] = []
        var cursor = CMTime.zero
        /// Position of the current segment's start along the *whole* drive, which is what
        /// a clip range is expressed against.
        var sourceCursor: TimeInterval = 0

        for segment in segments {
            let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0
            else { continue }

            // Keep only the part of this segment that falls inside the requested clip.
            guard let source = sourceRange(for: duration, sourceStart: sourceCursor, clip: clip) else {
                sourceCursor += duration.seconds
                continue
            }
            sourceCursor += duration.seconds

            try videoTrack.insertTimeRange(source, of: sourceVideo, at: cursor)
            placements.append(Placement(
                range: CMTimeRange(start: cursor, duration: source.duration),
                naturalSize: (try? await sourceVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080),
                transform: (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            ))

            if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(source, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, source.duration)
        }

        guard cursor.seconds > 0, let first = placements.first else { throw BuildError.noFootage }
        // Only meaningful when every segment agrees; a mixed drive is composited instead.
        videoTrack.preferredTransform = first.transform

        return Assembled(
            composition: composition,
            placements: placements,
            duration: cursor,
            renderSize: dominantRenderSize(of: placements),
            startDate: clip.map { segments[0].startDate.addingTimeInterval($0.start) } ?? segments[0].startDate,
            frameRate: segments.first?.fps ?? 30,
            hasMixedGeometry: isMixed(placements)
        )
    }

    /// Intersects one segment with the requested clip, in the segment's own coordinates.
    /// Returns nil when the segment lies entirely outside the clip.
    static func sourceRange(for duration: CMTime, sourceStart: TimeInterval, clip: ClipRange?) -> CMTimeRange? {
        guard let clip else { return CMTimeRange(start: .zero, duration: duration) }
        let segmentEnd = sourceStart + duration.seconds
        let from = max(sourceStart, clip.start)
        let to = min(segmentEnd, clip.end)
        guard to > from else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: from - sourceStart, preferredTimescale: 600),
            duration: CMTime(seconds: to - from, preferredTimescale: 600)
        )
    }

    // MARK: - Geometry

    /// The shape that occupies most of the drive. Turning the phone for twenty seconds of
    /// a half-hour trip must not letterbox the other twenty-nine minutes.
    private static func dominantRenderSize(of placements: [Placement]) -> CGSize {
        var totals: [String: (size: CGSize, seconds: Double)] = [:]
        for placement in placements {
            let size = displaySize(naturalSize: placement.naturalSize, transform: placement.transform)
            let key = "\(Int(size.width))x\(Int(size.height))"
            totals[key, default: (size, 0)].seconds += placement.range.duration.seconds
        }
        return totals.values.max { $0.seconds < $1.seconds }?.size ?? CGSize(width: 1920, height: 1080)
    }

    private static func isMixed(_ placements: [Placement]) -> Bool {
        let sizes = Set(placements.map { placement -> String in
            let size = displaySize(naturalSize: placement.naturalSize, transform: placement.transform)
            return "\(Int(size.width))x\(Int(size.height))"
        })
        return sizes.count > 1
    }

    private static func placement(at time: CMTime, in placements: [Placement]) -> Placement? {
        placements.first { $0.range.containsTime(time) }
    }

    /// Cuts the timeline at every boundary present in any of the given tracks, so each
    /// resulting slice has a single, stable geometry for every layer.
    private static func slices(of groups: [[Placement]], upTo end: CMTime) -> [CMTimeRange] {
        var boundaries: Set<Double> = [0, end.seconds]
        for group in groups {
            for placement in group {
                boundaries.insert(placement.range.start.seconds)
                boundaries.insert(min(placement.range.end.seconds, end.seconds))
            }
        }
        let ordered = boundaries.filter { $0 >= 0 && $0 <= end.seconds }.sorted()
        var ranges: [CMTimeRange] = []
        for (start, stop) in zip(ordered, ordered.dropFirst()) where stop > start {
            ranges.append(CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: stop, preferredTimescale: 600)
            ))
        }
        // A single placement produces a single slice; never return an empty instruction
        // list, which AVFoundation treats as "render nothing".
        return ranges.isEmpty ? [CMTimeRange(start: .zero, duration: end)] : ranges
    }

    /// Size the footage occupies once its preferred transform is applied.
    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(abs(rect.width)), height: even(abs(rect.height)))
    }

    /// Maps a source track into `target`, preserving aspect ratio and honouring the
    /// track's own rotation.
    ///
    /// The normalisation step is the one that is easy to miss: rotating a track moves its
    /// content off the origin, so without translating the bounding box back to zero,
    /// portrait-transformed footage composites entirely outside the render rect and the
    /// output is a black frame.
    static func fittingTransform(naturalSize: CGSize, preferred: CGAffineTransform, into target: CGRect) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        guard rect.width > 0, rect.height > 0 else { return preferred }

        var transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let scale = min(target.width / rect.width, target.height / rect.height)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let scaledWidth = rect.width * scale
        let scaledHeight = rect.height * scale
        let dx = target.minX + (target.width - scaledWidth) / 2
        let dy = target.minY + (target.height - scaledHeight) / 2
        return transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
    }
}
