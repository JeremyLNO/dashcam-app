import AVFoundation
import Foundation
import UIKit

/// Stills of the driver's own road, written into the shared container for the widget.
///
/// The one thing on that widget which *proves* footage exists rather than describing it:
/// a figure can be produced by a database row, a frame cannot. A drive that wrote nothing
/// has no still, and the widget shows its gradient instead — which is itself an answer.
///
/// Deliberately small and deliberately few: a widget extension is given a few tens of
/// megabytes and is killed without ceremony when it goes over. Four JPEGs of a few
/// kilobytes each is the whole budget this is allowed to spend.
enum StillStore {
    /// Wide enough for the large widget at 3×, and no wider.
    static let size = CGSize(width: 480, height: 270)
    static let quality: CGFloat = 0.7
    /// Newest drive plus three protected moments. Anything beyond that is never drawn.
    static let keep = 4

    static func name(for sessionID: UUID) -> String { "\(sessionID.uuidString).jpg" }
    static func name(for sessionID: UUID, event: UUID) -> String {
        "\(sessionID.uuidString)-\(event.uuidString).jpg"
    }

    /// Extracts one frame and writes it, unless it is already there.
    ///
    /// Returns whether a file now exists at that name — the caller reloads the widget only
    /// when something actually changed, because a reload the system did not need is a
    /// reload it will refuse later when it matters.
    @discardableResult
    static func write(named name: String, from url: URL, at seconds: TimeInterval) async -> Bool {
        guard let folder = DashcamSnapshotStore.stillsURL else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return true }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        // A generous tolerance on purpose, and the opposite of what a test needs: here any
        // frame near the mark is a picture of the same road, and insisting on an exact one
        // costs a decode of everything between the keyframes.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image,
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
        else { return false }
        return (try? data.write(to: destination, options: .atomic)) != nil
    }

    /// Everything the snapshot does not name is gone. Called after each write, so the
    /// folder never grows past what a widget can draw.
    static func sweep(keeping names: [String]) {
        guard let folder = DashcamSnapshotStore.stillsURL,
              let existing = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return }
        let wanted = Set(names)
        for file in existing where !wanted.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
}
