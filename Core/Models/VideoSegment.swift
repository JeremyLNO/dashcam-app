import Foundation
import SwiftData

/// One finalized chunk of footage from one camera.
///
/// Front and rear segments carrying the same `index` inside the same session cover the
/// same wall-clock window: that pairing, not a timestamp comparison, is what makes the
/// two-up player and the picture-in-picture export line up.
@Model
final class VideoSegment {
    // (`#Index` would help the library queries here, but it needs iOS 18 and the
    //  deployment floor is 17 so older iPhones can still run rear-only.)

    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    /// Raw value of `CameraPosition`.
    var cameraRaw: String
    /// 0-based position within the session, shared by the front/rear pair.
    var index: Int
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    /// Path relative to the recordings root, e.g. "<session-uuid>/rear_0003.mov".
    /// Never an absolute URL: see the note on `DriveSession`.
    var relativePath: String
    var fileSize: Int64
    var isProtected: Bool
    var width: Int
    var height: Int
    var fps: Int
    var codec: String
    /// SHA-256 of the file, computed once just after it is finalized and never again.
    /// Empty until that finishes, or if hashing failed. It is what makes an exported
    /// proof bundle checkable: anyone can re-hash the file and compare.
    var sha256: String
    /// False while the asset writer still owns the file. A non-finalized segment left
    /// over from a previous launch is what `RecoveryManager` repairs or discards.
    var isFinalized: Bool

    var session: DriveSession?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        camera: CameraPosition,
        index: Int,
        startDate: Date,
        endDate: Date,
        relativePath: String,
        fileSize: Int64 = 0,
        isProtected: Bool = false,
        width: Int,
        height: Int,
        fps: Int,
        codec: String,
        isFinalized: Bool = false,
        sha256: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cameraRaw = camera.rawValue
        self.index = index
        self.startDate = startDate
        self.endDate = endDate
        self.duration = max(0, endDate.timeIntervalSince(startDate))
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.isProtected = isProtected
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.isFinalized = isFinalized
        self.sha256 = sha256
    }

    var camera: CameraPosition { CameraPosition(rawValue: cameraRaw) ?? .rear }

    /// True when this segment overlaps the given window at all — the test the protection
    /// engine runs, so a 5-minute look-back correctly catches a segment that merely
    /// clips the start of the window.
    func overlaps(start: Date, end: Date) -> Bool {
        startDate < end && endDate > start
    }
}
