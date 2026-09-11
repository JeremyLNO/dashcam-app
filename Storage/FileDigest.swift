import CryptoKit
import Foundation

/// SHA-256 of a file, read in chunks.
///
/// Chunked on purpose: a five-minute 1080p segment is well over a hundred megabytes, and
/// `Data(contentsOf:)` would pull all of it into memory at the exact moment the app is
/// already juggling two camera streams.
enum FileDigest {
    /// 1 MB at a time — large enough that the syscall overhead disappears, small enough
    /// that the peak footprint stays irrelevant.
    private static let chunkSize = 1 << 20

    /// Returns the lowercase hex digest, or nil if the file could not be read.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
