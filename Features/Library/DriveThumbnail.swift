import AVFoundation
import SwiftUI

/// A still from the beginning of a drive, with its length written across the corner.
///
/// A dashcam library is a wall of near-identical rows without it — same shape, same
/// figures, different times. One frame of the road is what makes a drive recognisable.
///
/// The frame is read from the file already on disk; nothing is stored, and the small
/// in-memory cache exists so scrolling back up does not decode the same frame twice.
struct DriveThumbnail: View {
    let session: DriveSession
    var size: CGSize = CGSize(width: 104, height: 78)

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surfaceElevated)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        // The still is clipped to the frame *before* the badges go on: laid inside the
        // same stack, they were sized against the overflowing image and hung off both
        // edges.
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(Color(hex: 0x08264A).opacity(0.65)))
                .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(verbatim: Format.duration(session.duration))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(hex: 0x08264A).opacity(0.65)))
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: session.id) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard image == nil else { return }
        guard let segment = session.rearSegments.first ?? session.frontSegments.first else { return }
        let path = segment.relativePath
        if let cached = ThumbnailCache.shared.image(for: path) {
            image = cached
            return
        }
        let scale = await UIScreen.main.scale
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard let generated = await ThumbnailCache.shared.generate(for: path, size: pixelSize) else { return }
        image = generated
    }
}

/// Decodes one frame per file, at most once, off the main actor.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 120
    }

    nonisolated func image(for path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    func generate(for path: String, size: CGSize) async -> UIImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }

        let url = StorageLocations.absoluteURL(forRelativePath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        // Half a second in: the very first frame of a dashcam segment is often the
        // sensor still settling, and a grey rectangle makes a worse thumbnail than the
        // road does.
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)

        do {
            let cgImage = try await generator.image(at: time).image
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: path as NSString)
            return image
        } catch {
            Log.storage.debug("No thumbnail for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
