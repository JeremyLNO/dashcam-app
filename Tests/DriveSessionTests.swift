import SwiftData
import XCTest
@testable import Dashcam

@MainActor
final class DriveSessionTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var sessionID: UUID!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: start, quality: .high)
    }

    override func tearDown() async throws {
        TestSupport.removeSessionFiles(sessionID)
    }

    func testDurationOfAnOpenSessionFollowsItsLastSegment() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: start, duration: 180)
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: start.addingTimeInterval(180), duration: 120)

        let session = index.session(id: sessionID)!
        XCTAssertTrue(session.isOpen)
        XCTAssertEqual(session.duration, 300, accuracy: 0.001)
    }

    func testClosingASessionFixesItsDurationAndSize() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: start, duration: 60, bytes: 2048)
        TestSupport.addSegment(to: index, sessionID: sessionID, camera: .front, segmentIndex: 0, start: start, duration: 60, bytes: 1024)

        index.endSession(id: sessionID, endedAt: start.addingTimeInterval(60))
        let session = index.session(id: sessionID)!

        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.duration, 60, accuracy: 0.001)
        XCTAssertEqual(session.storageSize, 3072)
    }

    /// Front and rear segments with the same index are the pairing the player and the
    /// picture-in-picture export rely on.
    func testFrontAndRearSegmentsPairByIndex() {
        for i in 0..<3 {
            for camera in CameraPosition.allCases {
                TestSupport.addSegment(to: index, sessionID: sessionID, camera: camera, segmentIndex: i,
                                       start: start.addingTimeInterval(Double(i) * 60), duration: 60)
            }
        }
        let session = index.session(id: sessionID)!

        XCTAssertEqual(session.rearSegments.map(\.index), [0, 1, 2])
        XCTAssertEqual(session.frontSegments.map(\.index), [0, 1, 2])
        for (rear, front) in zip(session.rearSegments, session.frontSegments) {
            XCTAssertEqual(rear.startDate, front.startDate)
        }
    }

    /// A dual-camera drive writes two files per window. The library must report windows,
    /// not files — otherwise a nine-minute trip claims eighteen segments.
    func testSegmentCountReportsWindowsNotFiles() {
        for i in 0..<3 {
            for camera in CameraPosition.allCases {
                TestSupport.addSegment(to: index, sessionID: sessionID, camera: camera, segmentIndex: i,
                                       start: start.addingTimeInterval(Double(i) * 60), duration: 60)
            }
        }
        let session = index.session(id: sessionID)!

        XCTAssertEqual(session.segments.count, 6, "six files on disk")
        XCTAssertEqual(session.segmentCount, 3, "three windows in the drive")
    }

    /// A rear-only drive counts its own segments, with no front camera to pair against.
    func testSegmentCountHandlesRearOnlyDrives() {
        for i in 0..<4 {
            TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: i,
                                   start: start.addingTimeInterval(Double(i) * 60), duration: 60)
        }
        XCTAssertEqual(index.session(id: sessionID)!.segmentCount, 4)
    }

    func testQualityRoundTripsThroughItsRawValue() {
        XCTAssertEqual(index.session(id: sessionID)!.quality, .high)
    }

    func testHasProtectedContentReflectsAnySegment() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: start)
        XCTAssertFalse(index.session(id: sessionID)!.hasProtectedContent)

        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: start, isProtected: true)
        XCTAssertTrue(index.session(id: sessionID)!.hasProtectedContent)
    }

    func testDeletingASessionRemovesItsFilesFromDisk() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: start)
        let folder = StorageLocations.recordingsRoot.appendingPathComponent(sessionID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        index.deleteSession(index.session(id: sessionID)!)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(index.session(id: sessionID))
    }

    func testSegmentOverlapIsHalfOpen() {
        let segment = VideoSegment(
            sessionID: sessionID, camera: .rear, index: 0,
            startDate: start, endDate: start.addingTimeInterval(60),
            relativePath: "x", width: 1920, height: 1080, fps: 30, codec: "hvc1"
        )
        XCTAssertTrue(segment.overlaps(start: start.addingTimeInterval(59), end: start.addingTimeInterval(120)))
        XCTAssertFalse(segment.overlaps(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120)))
        XCTAssertFalse(segment.overlaps(start: start.addingTimeInterval(-60), end: start))
    }

    func testRelativePathFormatIsStableAndParsesBack() {
        let path = StorageLocations.relativePath(sessionID: sessionID, camera: .front, index: 7)
        XCTAssertEqual(path, "\(sessionID.uuidString)/front_0007.mov")

        let parsed = RecoveryManager.parseName("front_0007.mov")
        XCTAssertEqual(parsed?.camera, .front)
        XCTAssertEqual(parsed?.index, 7)
    }

    /// Turning the phone mid-window forces a second file at the same index; the revision
    /// suffix keeps the path unique while the front/rear pairing stays intact.
    func testRevisionSuffixKeepsTheIndexPairingIntact() {
        let base = StorageLocations.relativePath(sessionID: sessionID, camera: .rear, index: 7)
        let rotated = StorageLocations.relativePath(sessionID: sessionID, camera: .rear, index: 7, revision: 1)

        XCTAssertEqual(base, "\(sessionID.uuidString)/rear_0007.mov")
        XCTAssertEqual(rotated, "\(sessionID.uuidString)/rear_0007-1.mov")
        XCTAssertNotEqual(base, rotated)

        // Both still parse back to the same segment index, so recovery re-adopts them
        // into the right place in the sequence.
        XCTAssertEqual(RecoveryManager.parseName("rear_0007.mov")?.index, 7)
        XCTAssertEqual(RecoveryManager.parseName("rear_0007-1.mov")?.index, 7)
        XCTAssertEqual(RecoveryManager.parseName("front_0007-2.mov")?.camera, .front)
        XCTAssertEqual(RecoveryManager.parseName("front_0007-2.mov")?.index, 7)
    }

    func testParseNameRejectsAnythingItDoesNotRecognise() {
        XCTAssertNil(RecoveryManager.parseName("IMG_0001.mov"))
        XCTAssertNil(RecoveryManager.parseName("rear.mov"))
        XCTAssertNil(RecoveryManager.parseName("rear_abc.mov"))
    }
}
