import SwiftData
import XCTest
@testable import Dashcam

/// Protection: five minutes behind, two minutes ahead, across as many segments as that
/// happens to span.
@MainActor
final class EventProtectionManagerTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var protection: EventProtectionManager!
    private var sessionID: UUID!
    private let trigger = Date()

    override func setUp() async throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        protection = EventProtectionManager(index: index)
        sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: trigger.addingTimeInterval(-1800), quality: .standard)
    }

    override func tearDown() async throws {
        TestSupport.removeSessionFiles(sessionID)
    }

    /// One-minute segments: the five-minute look-back must pin all five, and nothing
    /// older.
    func testLookBackSpansEverySegmentItTouches() {
        for i in 0..<10 {
            // Segment i covers [trigger-10m+i, trigger-9m+i].
            TestSupport.addSegment(
                to: index, sessionID: sessionID, segmentIndex: i,
                start: trigger.addingTimeInterval(-600 + Double(i) * 60), duration: 60
            )
        }

        let pinned = protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)

        // Window starts at trigger-300, so segments 5..9 overlap it — five files.
        XCTAssertEqual(pinned, 5)
        let protectedIndexes = index.allSegments().filter(\.isProtected).map(\.index).sorted()
        XCTAssertEqual(protectedIndexes, [5, 6, 7, 8, 9])
    }

    /// A segment that merely clips the edge of the window still counts: overlap, not
    /// containment, is the test.
    func testPartialOverlapAtTheWindowEdgeIsProtected() {
        // Covers [trigger-330, trigger-270]; the window starts at trigger-300.
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0,
                               start: trigger.addingTimeInterval(-330), duration: 60)
        // Covers [trigger-360, trigger-300] — ends exactly on the boundary, so no overlap.
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 1,
                               start: trigger.addingTimeInterval(-360), duration: 60)

        let pinned = protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)

        XCTAssertEqual(pinned, 1)
        XCTAssertTrue(index.allSegments().first { $0.index == 0 }!.isProtected)
        XCTAssertFalse(index.allSegments().first { $0.index == 1 }!.isProtected)
    }

    func testForwardWindowClaimsSegmentsThatDoNotExistYet() {
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)

        // Recorded 30 seconds after the press: inside the two-minute look-ahead.
        XCTAssertTrue(protection.shouldProtectSegment(
            sessionID: sessionID,
            start: trigger.addingTimeInterval(30),
            end: trigger.addingTimeInterval(90)
        ))
        // Recorded three minutes later: the window has closed.
        XCTAssertFalse(protection.shouldProtectSegment(
            sessionID: sessionID,
            start: trigger.addingTimeInterval(180),
            end: trigger.addingTimeInterval(240)
        ))
    }

    func testBothCamerasAreProtectedForTheSameWindow() {
        for camera in CameraPosition.allCases {
            TestSupport.addSegment(to: index, sessionID: sessionID, camera: camera, segmentIndex: 0,
                                   start: trigger.addingTimeInterval(-60), duration: 60)
        }

        let pinned = protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .impact, magnitude: 3.1)

        XCTAssertEqual(pinned, 2)
        XCTAssertTrue(index.allSegments().allSatisfy(\.isProtected))
    }

    func testRemovingProtectionReleasesSegmentsNoOtherEventClaims() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0,
                               start: trigger.addingTimeInterval(-60), duration: 60)
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        let event = index.activeEvents(forSession: sessionID).first!

        protection.removeProtection(event: event)

        XCTAssertFalse(index.allSegments()[0].isProtected)
        XCTAssertTrue(index.activeEvents(forSession: sessionID).isEmpty)
    }

    /// Two overlapping events: dropping one must not release footage the other still
    /// wants.
    func testOverlappingEventsKeepSegmentsProtected() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0,
                               start: trigger.addingTimeInterval(-60), duration: 60)
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        protection.protect(sessionID: sessionID, triggerDate: trigger.addingTimeInterval(30), origin: .impact, magnitude: 2.9)

        let first = index.activeEvents(forSession: sessionID).sorted { $0.triggerDate < $1.triggerDate }[0]
        protection.removeProtection(event: first)

        XCTAssertTrue(index.allSegments()[0].isProtected, "the second event still covers this segment")
    }

    /// Releasing a whole drive has to deactivate its open events too, or the next
    /// finalized segment would immediately re-protect what the user just released.
    func testUnprotectingASessionClosesItsOpenWindows() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0,
                               start: trigger.addingTimeInterval(-60), duration: 60)
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        let session = index.session(id: sessionID)!

        protection.setProtection(false, for: session)

        XCTAssertTrue(index.activeEvents(forSession: sessionID).isEmpty)
        XCTAssertFalse(protection.shouldProtectSegment(
            sessionID: sessionID,
            start: trigger.addingTimeInterval(10),
            end: trigger.addingTimeInterval(70)
        ))
    }

    func testWindowGeometryMatchesTheSpecifiedFiveAndTwoMinutes() {
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        let event = index.activeEvents(forSession: sessionID).first!
        XCTAssertEqual(event.windowStart.timeIntervalSince(trigger), -300, accuracy: 0.001)
        XCTAssertEqual(event.windowEnd.timeIntervalSince(trigger), 120, accuracy: 0.001)
    }
}
