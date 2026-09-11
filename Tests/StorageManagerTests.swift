import SwiftData
import XCTest
@testable import Dashcam

/// `StorageManager` measures the filesystem rather than trusting the database, so its
/// measurement is worth testing against real files.
@MainActor
final class StorageManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var storage: StorageManager!
    private var sessionID: UUID!

    override func setUp() async throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        storage = StorageManager(index: index)
        sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: Date(), quality: .standard)
    }

    override func tearDown() async throws {
        TestSupport.removeSessionFiles(sessionID)
    }

    func testDirectorySizeCountsFilesNestedInSessionFolders() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: Date(), bytes: 40_000)
        TestSupport.addSegment(to: index, sessionID: sessionID, camera: .front, segmentIndex: 0, start: Date(), bytes: 20_000)

        let measured = StorageManager.directorySize(StorageLocations.recordingsRoot)
        XCTAssertGreaterThanOrEqual(measured, 60_000, "both nested files must be counted")
    }

    func testRefreshReportsWhatIsActuallyOnDisk() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: Date(), bytes: 50_000)

        let snapshot = storage.refresh()

        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.segmentCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.dashcamBytes, 50_000)
        XCTAssertGreaterThan(snapshot.freeBytes, 0)
    }

    func testProtectedBytesAreReportedSeparately() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: Date(), bytes: 10_000, isProtected: true)
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: Date(), bytes: 30_000)

        let snapshot = storage.refresh()
        XCTAssertEqual(snapshot.protectedBytes, 10_000)
    }

    func testFileSizeReadsASingleFile() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: Date(), bytes: 12_345)
        let url = StorageLocations.absoluteURL(
            forRelativePath: StorageLocations.relativePath(sessionID: sessionID, camera: .rear, index: 0)
        )
        XCTAssertEqual(StorageManager.fileSize(at: url), 12_345)
    }
}

/// `RecoveryManager` reconciles the database with the filesystem after a crash, a restore
/// or anything else that moves one without the other.
@MainActor
final class RecoveryManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var recovery: RecoveryManager!
    private var sessionID: UUID!

    override func setUp() async throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        recovery = RecoveryManager(index: index)
        sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: Date().addingTimeInterval(-600), quality: .standard)
    }

    override func tearDown() async throws {
        TestSupport.removeSessionFiles(sessionID)
    }

    /// The failure this test was written for: the library showed two drives sized 29 KB
    /// each after their files had been deleted underneath it.
    func testRowsWhoseFileIsGoneAreDropped() async {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: Date().addingTimeInterval(-600))
        index.endSession(id: sessionID, endedAt: Date().addingTimeInterval(-540))
        XCTAssertEqual(index.allSegments().count, 1)

        // Wipe the footage without telling the database — a restore, or a manual clean.
        TestSupport.removeSessionFiles(sessionID)

        let report = await recovery.recover()

        XCTAssertEqual(report.droppedDanglingRows, 1)
        XCTAssertTrue(index.allSegments().isEmpty)
        XCTAssertTrue(index.allSessions().isEmpty, "a drive with nothing left is not a drive")
    }

    func testIntactSegmentsAreLeftAlone() async {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: Date().addingTimeInterval(-600))

        let report = await recovery.recover()

        XCTAssertEqual(report.droppedDanglingRows, 0)
        XCTAssertEqual(index.allSegments().count, 1)
    }

    /// A session left open by a crash is closed at its last segment rather than staying
    /// open forever and blocking the retention sweep.
    func testAnOpenSessionIsClosedAtItsLastSegment() async {
        let start = Date().addingTimeInterval(-600)
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: start, duration: 60)
        XCTAssertTrue(index.session(id: sessionID)!.isOpen)

        let report = await recovery.recover()

        XCTAssertEqual(report.closedSessions, 1)
        XCTAssertEqual(index.session(id: sessionID)?.endedAt?.timeIntervalSince1970 ?? 0,
                       start.addingTimeInterval(60).timeIntervalSince1970, accuracy: 0.001)
    }

    /// A folder with no matching session row is a leftover from a deleted drive.
    func testFoldersWithNoSessionRowAreRemoved() async {
        let orphanID = UUID()
        let folder = StorageLocations.sessionDirectory(orphanID)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("rear_0000.mov").path, contents: Data(count: 16))

        _ = await recovery.recover()

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
