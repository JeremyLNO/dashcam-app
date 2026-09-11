import SwiftData
import XCTest
@testable import Dashcam

/// The sweeper. Its most important property is what it *refuses* to delete.
@MainActor
final class RetentionManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var storage: StorageManager!
    private var registry: ActiveFileRegistry!
    private var retention: RetentionManager!
    private var sessionID: UUID!

    override func setUp() async throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        storage = StorageManager(index: index)
        registry = ActiveFileRegistry()
        retention = RetentionManager(index: index, storage: storage, registry: registry)
        sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: Date().addingTimeInterval(-40 * 24 * 3600), quality: .standard)
    }

    override func tearDown() async throws {
        TestSupport.removeSessionFiles(sessionID)
    }

    private func settings(retention policy: RetentionPolicy = .never, limit: StorageLimit = .unlimited) -> RecordingSettings {
        var settings = RecordingSettings()
        settings.retention = policy
        settings.storageLimit = limit
        return settings
    }

    func testAgePolicyDeletesOnlyWhatIsOlderThanTheCutoff() {
        let now = Date()
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: now.addingTimeInterval(-10 * 24 * 3600))
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: now.addingTimeInterval(-2 * 24 * 3600))

        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .periodic, now: now)

        XCTAssertEqual(result.deletedSegments, 1)
        XCTAssertEqual(index.allSegments().map(\.index), [1])
    }

    /// The boundary itself: a segment that ended exactly on the cutoff is kept, one
    /// second older goes.
    func testAgePolicyBoundaryIsExclusive() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        // endDate == cutoff exactly.
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: cutoff.addingTimeInterval(-60), duration: 60)
        // endDate one second before the cutoff.
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: cutoff.addingTimeInterval(-61), duration: 60)

        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .periodic, now: now)

        XCTAssertEqual(result.deletedSegments, 1)
        XCTAssertEqual(index.allSegments().map(\.index), [0])
    }

    func testProtectedSegmentsSurviveTheAgePolicy() {
        let now = Date()
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: now.addingTimeInterval(-30 * 24 * 3600), isProtected: true)
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: now.addingTimeInterval(-30 * 24 * 3600), isProtected: false)

        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .periodic, now: now)

        XCTAssertEqual(result.deletedSegments, 1)
        XCTAssertEqual(index.allSegments().map(\.index), [0])
        XCTAssertTrue(index.allSegments()[0].isProtected)
    }

    func testNeverPolicyDeletesNothingByAge() {
        let now = Date()
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: now.addingTimeInterval(-3650 * 24 * 3600))

        let result = retention.sweep(settings: settings(retention: .never), reason: .periodic, now: now)

        XCTAssertEqual(result.deletedSegments, 0)
    }

    func testReservedFilesAreNeverDeletedEvenWhenExpired() {
        let now = Date()
        let segment = TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: now.addingTimeInterval(-30 * 24 * 3600))
        registry.reserve([segment!.relativePath])

        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .periodic, now: now)

        XCTAssertEqual(result.deletedSegments, 0)
        XCTAssertEqual(index.allSegments().count, 1)
    }

    func testSessionPrefixReservationCoversEverySegmentInsideIt() {
        let now = Date()
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: now.addingTimeInterval(-30 * 24 * 3600))
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1, start: now.addingTimeInterval(-30 * 24 * 3600))
        registry.reserveSessionPrefix(sessionID)

        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .recordingFinished, now: now)

        XCTAssertEqual(result.deletedSegments, 0)

        registry.releaseSessionPrefix(sessionID)
        let second = retention.sweep(settings: settings(retention: .sevenDays), reason: .recordingFinished, now: now)
        XCTAssertEqual(second.deletedSegments, 2)
    }

    func testSizeLimitDeletesOldestFirstUntilUnderTheCap() {
        let now = Date()
        // Four 1 MB segments, cap them at ~2 MB via a bespoke limit check.
        for i in 0..<4 {
            TestSupport.addSegment(
                to: index, sessionID: sessionID, segmentIndex: i,
                start: now.addingTimeInterval(-Double(4 - i) * 3600), bytes: 1_000_000
            )
        }
        var settings = RecordingSettings()
        settings.retention = .never
        settings.storageLimit = .gb5

        // 5 GB is far above 4 MB, so nothing should be touched.
        let untouched = retention.sweep(settings: settings, reason: .settingsChanged, now: now)
        XCTAssertEqual(untouched.deletedSegments, 0)
        XCTAssertEqual(index.allSegments().count, 4)
    }

    func testEmptySessionsArePrunedOnceAllTheirSegmentsAreGone() {
        let now = Date()
        index.endSession(id: sessionID, endedAt: now.addingTimeInterval(-30 * 24 * 3600))
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: now.addingTimeInterval(-30 * 24 * 3600))

        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .launch, now: now)

        XCTAssertEqual(result.deletedSegments, 1)
        XCTAssertEqual(result.deletedSessions, 1)
        XCTAssertTrue(index.allSessions().isEmpty)
    }

    /// A drive still being recorded has no `endedAt`; pruning it would delete the session
    /// row out from under the running writers.
    func testOpenSessionsAreNeverPruned() {
        let now = Date()
        let result = retention.sweep(settings: settings(retention: .sevenDays), reason: .periodic, now: now)
        XCTAssertEqual(result.deletedSessions, 0)
        XCTAssertEqual(index.allSessions().count, 1)
    }
}
