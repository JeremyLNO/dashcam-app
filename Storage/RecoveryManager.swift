import AVFoundation
import Foundation

struct RecoveryReport: Equatable, Sendable {
    var repairedSegments: Int = 0
    var discardedFiles: Int = 0
    var adoptedOrphans: Int = 0
    var closedSessions: Int = 0
    /// Rows whose file is gone. The library would otherwise list drives that cannot be
    /// played and report sizes for bytes that no longer exist.
    var droppedDanglingRows: Int = 0
}

/// Repairs the gap between "what is on disk" and "what the database says" after a crash
/// or a power cut.
///
/// Three kinds of damage are handled:
///
/// * **A session left open.** The app died mid-drive, so `endedAt` was never written.
///   It is closed at its last segment's end.
/// * **An orphan file.** A segment finished on disk but the process died before the row
///   was inserted. If the movie is readable it is adopted into the session.
/// * **A torn file.** The segment that was being written when the power went. Thanks to
///   `movieFragmentInterval` these are often still playable; if `AVAsset` can read a
///   duration the file is adopted, otherwise it is removed.
/// * **A dangling row.** The mirror image of an orphan: the database remembers a segment
///   whose file is gone (a restore that skipped the excluded-from-backup directory, a
///   manual wipe, an interrupted delete). Left alone it becomes a drive in the library
///   that plays nothing and inflates every storage figure.
@MainActor
final class RecoveryManager {
    private let index: SessionIndex

    init(index: SessionIndex) {
        self.index = index
    }

    @discardableResult
    func recover() async -> RecoveryReport {
        var report = RecoveryReport()

        let sessions = index.allSessions()
        var known = Set<String>()
        for session in sessions {
            for segment in session.segments { known.insert(segment.relativePath) }
        }

        for session in sessions {
            // Drop rows whose file no longer exists, before anything else looks at them.
            for segment in session.segments {
                let url = StorageLocations.absoluteURL(forRelativePath: segment.relativePath)
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                known.remove(segment.relativePath)
                index.deleteSegment(segment)
                report.droppedDanglingRows += 1
            }

            // Adopt anything on disk the index does not know about.
            let folder = StorageLocations.recordingsRoot.appendingPathComponent(session.folderName, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension.lowercased() == "mov" {
                let relativePath = "\(session.folderName)/\(url.lastPathComponent)"
                guard !known.contains(relativePath) else { continue }

                guard let descriptor = await Self.inspect(url: url) else {
                    try? FileManager.default.removeItem(at: url)
                    report.discardedFiles += 1
                    continue
                }
                guard let parsed = Self.parseName(url.lastPathComponent) else {
                    try? FileManager.default.removeItem(at: url)
                    report.discardedFiles += 1
                    continue
                }

                // Wall-clock start is unknown for an orphan, so it is reconstructed from
                // the session start plus the segment's position in the sequence. Good
                // enough to keep the library ordering and the front/rear pairing honest.
                let start = session.startedAt.addingTimeInterval(Double(parsed.index) * descriptor.duration)
                let finished = FinishedSegment(
                    camera: parsed.camera,
                    index: parsed.index,
                    startDate: start,
                    endDate: start.addingTimeInterval(descriptor.duration),
                    relativePath: relativePath,
                    fileSize: StorageManager.fileSize(at: url),
                    width: descriptor.width,
                    height: descriptor.height,
                    fps: descriptor.fps,
                    codec: descriptor.codec,
                    succeeded: true
                )
                index.insertSegment(finished, sessionID: session.id, isProtected: false)
                report.adoptedOrphans += 1
                if descriptor.wasTorn { report.repairedSegments += 1 }
            }

            if session.isOpen {
                let end = session.segments.map(\.endDate).max() ?? session.startedAt
                index.endSession(id: session.id, endedAt: end)
                report.closedSessions += 1
            }
        }

        // Folders with no matching session row are leftovers from a deleted drive.
        let roots = (try? FileManager.default.contentsOfDirectory(at: StorageLocations.recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        let knownFolders = Set(sessions.map(\.folderName))
        for folder in roots where !knownFolders.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
            report.discardedFiles += 1
        }

        // A closed session with nothing left on disk is a ghost in the library.
        for session in index.allSessions() where session.segments.isEmpty && !session.isOpen {
            index.deleteSession(session)
        }

        StorageLocations.clearExports()
        Log.storage.info("Recovery: adopted \(report.adoptedOrphans), dropped \(report.droppedDanglingRows), discarded \(report.discardedFiles), closed \(report.closedSessions)")
        return report
    }

    // MARK: - Helpers

    struct AssetDescriptor: Sendable {
        var duration: TimeInterval
        var width: Int
        var height: Int
        var fps: Int
        var codec: String
        var wasTorn: Bool
    }

    /// Returns nil when the file cannot be read at all — that is the signal to delete it.
    static func inspect(url: URL) async -> AssetDescriptor? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.isValid, CMTimeGetSeconds(duration) > 0.2,
              let track = try? await asset.loadTracks(withMediaType: .video).first
        else { return nil }

        let size = (try? await track.load(.naturalSize)) ?? .zero
        let rate = (try? await track.load(.nominalFrameRate)) ?? 30
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let codec: String = formats.first.map { description in
            let raw = CMFormatDescriptionGetMediaSubType(description)
            return String(bytes: [
                UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF),
            ], encoding: .ascii) ?? AVVideoCodecType.hevc.rawValue
        } ?? AVVideoCodecType.hevc.rawValue

        // A torn file kept by fragment recovery is typically missing its tail: flagged so
        // the report can say something happened, but still perfectly usable.
        let torn = (try? await asset.load(.isPlayable)) == false

        return AssetDescriptor(
            duration: CMTimeGetSeconds(duration),
            width: Int(abs(size.width)),
            height: Int(abs(size.height)),
            fps: Int(rate.rounded()),
            codec: codec,
            wasTorn: torn
        )
    }

    /// "rear_0003.mov" -> (.rear, 3). "rear_0003-1.mov" -> (.rear, 3) as well: the
    /// revision suffix marks a file the writer had to reopen mid-window after the phone
    /// was turned, and it belongs to the same segment index.
    static func parseName(_ fileName: String) -> (camera: CameraPosition, index: Int)? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_")
        guard parts.count == 2,
              let camera = CameraPosition(rawValue: String(parts[0]))
        else { return nil }
        let indexPart = parts[1].split(separator: "-")[0]
        guard let index = Int(indexPart) else { return nil }
        return (camera, index)
    }
}
