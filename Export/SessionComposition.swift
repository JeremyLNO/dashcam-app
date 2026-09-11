import AVFoundation
import Foundation

/// A composition plus everything needed to play or export it.
struct BuiltComposition {
    let composition: AVMutableComposition
    /// Non-nil whenever the frames need laying out (picture-in-picture, or an overlay).
    let videoComposition: AVMutableVideoComposition?
    let duration: CMTime
    let renderSize: CGSize
    /// Wall-clock time of the first frame, used to line the overlay stamps up.
    let startDate: Date
    let frameRate: Int
}

/// Stitches a session's segments back into a continuous timeline.
///
/// Shared deliberately between playback and export: the two-up player the user reviews
/// footage in is the *same* composition the export writes out, so what they scrub through
/// is exactly what they will send to an insurer.
enum SessionComposition {
    enum BuildError: Error { case noFootage, trackCreationFailed }

    /// One camera, concatenated in segment order.
    static func single(segments: [VideoSegment], includeAudio: Bool) async throws -> BuiltComposition {
        guard !segments.isEmpty else { throw BuildError.noFootage }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.trackCreationFailed
        }
        let audioTrack = includeAudio
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        var transform = CGAffineTransform.identity
        var naturalSize = CGSize(width: 1920, height: 1080)

        for segment in segments {
            let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0
            else { continue }

            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? naturalSize

            if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor.seconds > 0 else { throw BuildError.noFootage }
        videoTrack.preferredTransform = transform

        let fps = segments.first?.fps ?? 30
        return BuiltComposition(
            composition: composition,
            videoComposition: nil,
            duration: cursor,
            renderSize: displaySize(naturalSize: naturalSize, transform: transform),
            startDate: segments[0].startDate,
            frameRate: fps
        )
    }

    /// Same as `single`, but with an explicit video composition so an overlay can be
    /// attached (Core Animation needs a video composition to hang off).
    static func singleWithLayout(segments: [VideoSegment], includeAudio: Bool) async throws -> BuiltComposition {
        let built = try await single(segments: segments, includeAudio: includeAudio)
        guard let track = built.composition.tracks(withMediaType: .video).first else { return built }

        let naturalSize = track.naturalSize
        let transform = track.preferredTransform
        let renderSize = displaySize(naturalSize: naturalSize, transform: transform)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(built.frameRate))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            fittingTransform(naturalSize: naturalSize, preferred: transform, into: CGRect(origin: .zero, size: renderSize)),
            at: .zero
        )
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        return BuiltComposition(
            composition: built.composition,
            videoComposition: videoComposition,
            duration: built.duration,
            renderSize: renderSize,
            startDate: built.startDate,
            frameRate: built.frameRate
        )
    }

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

        var rearCursor = CMTime.zero
        var rearTransform = CGAffineTransform.identity
        var rearSize = CGSize(width: 1920, height: 1080)

        for segment in rear {
            let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try rearTrack.insertTimeRange(range, of: track, at: rearCursor)
            rearTransform = (try? await track.load(.preferredTransform)) ?? .identity
            rearSize = (try? await track.load(.naturalSize)) ?? rearSize
            if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: rearCursor)
            }
            rearCursor = CMTimeAdd(rearCursor, duration)
        }
        guard rearCursor.seconds > 0 else { throw BuildError.noFootage }

        var frontCursor = CMTime.zero
        var frontTransform = CGAffineTransform.identity
        var frontSize = CGSize(width: 1920, height: 1080)

        for segment in front {
            let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            let remaining = CMTimeSubtract(rearCursor, frontCursor)
            guard remaining.seconds > 0 else { break }
            let used = CMTimeMinimum(duration, remaining)
            try frontTrack.insertTimeRange(CMTimeRange(start: .zero, duration: used), of: track, at: frontCursor)
            frontTransform = (try? await track.load(.preferredTransform)) ?? .identity
            frontSize = (try? await track.load(.naturalSize)) ?? frontSize
            frontCursor = CMTimeAdd(frontCursor, used)
        }

        let renderSize = displaySize(naturalSize: rearSize, transform: rearTransform)
        let fps = rear.first?.fps ?? 30

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let margin = renderSize.width * 0.025
        let insetWidth = renderSize.width * 0.28
        let insetHeight = insetWidth * (renderSize.height / max(1, renderSize.width))
        let insetRect = CGRect(
            x: renderSize.width - insetWidth - margin,
            y: renderSize.height - insetHeight - margin,
            width: insetWidth,
            height: insetHeight
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: rearCursor)

        let rearLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: rearTrack)
        rearLayer.setTransform(
            fittingTransform(naturalSize: rearSize, preferred: rearTransform, into: CGRect(origin: .zero, size: renderSize)),
            at: .zero
        )
        let frontLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontTrack)
        frontLayer.setTransform(
            fittingTransform(naturalSize: frontSize, preferred: frontTransform, into: insetRect),
            at: .zero
        )
        // Array order is front-to-back, so the cabin inset has to come first to sit on top.
        instruction.layerInstructions = [frontLayer, rearLayer]
        videoComposition.instructions = [instruction]

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            duration: rearCursor,
            renderSize: renderSize,
            startDate: rear[0].startDate,
            frameRate: fps
        )
    }

    // MARK: - Geometry

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
