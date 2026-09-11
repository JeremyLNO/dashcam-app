import Foundation
import SwiftData
import XCTest
@testable import Dashcam

/// Shared scaffolding: an in-memory store plus a scratch recordings tree, so no test ever
/// depends on — or damages — real footage.
@MainActor
enum TestSupport {
    /// The container has to be handed back and held by the test: a `SessionIndex` alone
    /// does not keep it alive, and a released container turns the next `insert` into a
    /// trap inside SwiftData rather than a clean failure.
    static func makeStore() -> (container: ModelContainer, index: SessionIndex) {
        let container = PersistenceController.makeContainer(inMemory: true)
        return (container, SessionIndex(container: container))
    }

    /// Creates a segment row *and* a file of the requested size, because the retention
    /// sweep measures the filesystem, not the database.
    @discardableResult
    static func addSegment(
        to index: SessionIndex,
        sessionID: UUID,
        camera: CameraPosition = .rear,
        segmentIndex: Int,
        start: Date,
        duration: TimeInterval = 60,
        bytes: Int = 1024,
        isProtected: Bool = false
    ) -> VideoSegment? {
        let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: segmentIndex)
        let url = StorageLocations.absoluteURL(forRelativePath: relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))

        let finished = FinishedSegment(
            camera: camera,
            index: segmentIndex,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            relativePath: relativePath,
            fileSize: Int64(bytes),
            width: 1920, height: 1080, fps: 30,
            codec: "hvc1",
            succeeded: true
        )
        return index.insertSegment(finished, sessionID: sessionID, isProtected: isProtected)
    }

    static func removeSessionFiles(_ sessionID: UUID) {
        let folder = StorageLocations.recordingsRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}
