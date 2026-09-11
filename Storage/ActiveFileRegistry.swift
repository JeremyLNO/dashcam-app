import Foundation

/// The set of files that must not be deleted right now because something is writing to
/// them or reading from them.
///
/// The retention sweep consults this before every unlink. Without it, a size-cap sweep
/// triggered mid-drive would happily delete the segment the asset writer still has open,
/// or the source of an export that is halfway through rendering.
final class ActiveFileRegistry: @unchecked Sendable {
    private var reserved: Set<String> = []
    private let lock = NSLock()

    func reserve(_ relativePaths: [String]) {
        lock.lock(); defer { lock.unlock() }
        relativePaths.forEach { reserved.insert($0) }
    }

    func release(_ relativePaths: [String]) {
        lock.lock(); defer { lock.unlock() }
        relativePaths.forEach { reserved.remove($0) }
    }

    /// Reserves a whole session's folder prefix — used while it is being recorded, when
    /// the individual segment names are not all known yet.
    func reserveSessionPrefix(_ sessionID: UUID) {
        reserve([sessionID.uuidString + "/"])
    }

    func releaseSessionPrefix(_ sessionID: UUID) {
        release([sessionID.uuidString + "/"])
    }

    func isReserved(_ relativePath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reserved.contains(relativePath) { return true }
        return reserved.contains { $0.hasSuffix("/") && relativePath.hasPrefix($0) }
    }
}
