import Foundation

/// Where everything lives on disk, in one place.
///
/// Recordings go in Application Support (not Documents): they are app-managed data, not
/// user documents, and they must never appear in the Files app or be swept into an
/// iCloud backup — a week of dual-camera footage would blow up the user's backup.
enum StorageLocations {
    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Root of every recorded file. Created on first access and excluded from backup.
    static var recordingsRoot: URL {
        var url = applicationSupport.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    /// Scratch space for export renders. Cleared on launch — a half-written export has
    /// no value after the process that was writing it went away.
    static var exportsRoot: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sessionDirectory(_ sessionID: UUID) -> URL {
        let url = recordingsRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "<session>/rear_0003.mov" — the exact string stored in `VideoSegment.relativePath`.
    ///
    /// A `revision` above zero appends "-1", "-2"… That happens when the phone is turned
    /// mid-window: the frames change shape, the writer has to open a new file, and the
    /// segment index must stay put so the front and rear numbering keeps lining up.
    static func relativePath(sessionID: UUID, camera: CameraPosition, index: Int, revision: Int = 0) -> String {
        let suffix = revision > 0 ? "-\(revision)" : ""
        return String(format: "%@/%@_%04d%@.mov", sessionID.uuidString, camera.rawValue, index, suffix)
    }

    static func absoluteURL(forRelativePath path: String) -> URL {
        recordingsRoot.appendingPathComponent(path)
    }

    /// Creates the folder a segment is about to be written into, and returns its URL.
    ///
    /// `absoluteURL(forRelativePath:)` is a pure path computation on purpose, so something
    /// has to create the session folder before an `AVAssetWriter` can open a file in it —
    /// the writer will not create intermediate directories, it just fails.
    @discardableResult
    static func prepareURL(forRelativePath path: String) -> URL {
        let url = absoluteURL(forRelativePath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return url
    }

    static func clearExports() {
        try? FileManager.default.removeItem(at: exportsRoot)
    }

    /// Used only by the persistence fallback path when the store cannot be opened.
    static func removeStoreFiles() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: applicationSupport, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("default.store") {
            try? fm.removeItem(at: url)
        }
    }
}
