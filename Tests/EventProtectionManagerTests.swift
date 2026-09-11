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
        // Segment covers [trigger-60, trigger].
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0,
                               start: trigger.addingTimeInterval(-60), duration: 60)
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        // An impact five seconds before the press: its ±10 s window lands inside the
        // segment too, so both events claim it.
        protection.protect(sessionID: sessionID, triggerDate: trigger.addingTimeInterval(-5),
                           origin: .impact, magnitude: 2.9)

        let manual = index.activeEvents(forSession: sessionID).first { $0.origin == .manual }!
        protection.removeProtection(event: manual)

        XCTAssertTrue(index.allSegments()[0].isProtected, "the impact still covers this segment")
    }

    /// The flip side, and the reason the window length matters: an automatic event only
    /// reaches ten seconds, so a second event well clear of the segment does not keep it.
    func testAnEventOutsideTheSegmentDoesNotKeepItProtected() {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0,
                               start: trigger.addingTimeInterval(-60), duration: 60)
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        // Thirty seconds later: window [trigger+20, trigger+40], nowhere near the segment.
        protection.protect(sessionID: sessionID, triggerDate: trigger.addingTimeInterval(30),
                           origin: .impact, magnitude: 2.9)

        let manual = index.activeEvents(forSession: sessionID).first { $0.origin == .manual }!
        protection.removeProtection(event: manual)

        XCTAssertFalse(index.allSegments()[0].isProtected, "nothing claims this segment any more")
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

    /// An automatic event is timestamped by the sensor, so it needs no reaction margin:
    /// ten seconds either side of the impact, not the manual button's five minutes.
    func testAnImpactProtectsTenSecondsEitherSide() {
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .impact, magnitude: 3.2)
        let event = index.activeEvents(forSession: sessionID).first!

        XCTAssertEqual(event.windowStart.timeIntervalSince(trigger), -10, accuracy: 0.001)
        XCTAssertEqual(event.windowEnd.timeIntervalSince(trigger), 10, accuracy: 0.001)
    }

    func testHarshBrakingUsesTheSameTightWindowAsAnImpact() {
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .harshBraking, magnitude: 0.6)
        let event = index.activeEvents(forSession: sessionID).first!

        XCTAssertEqual(event.windowStart.timeIntervalSince(trigger), -10, accuracy: 0.001)
        XCTAssertEqual(event.windowEnd.timeIntervalSince(trigger), 10, accuracy: 0.001)
    }

    /// CarPlay's Protect is a person pressing a button, so it keeps the generous window.
    func testCarPlayProtectKeepsTheManualWindow() {
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .carPlay)
        let event = index.activeEvents(forSession: sessionID).first!

        XCTAssertEqual(event.windowStart.timeIntervalSince(trigger), -300, accuracy: 0.001)
        XCTAssertEqual(event.windowEnd.timeIntervalSince(trigger), 120, accuracy: 0.001)
    }

    func testWindowGeometryMatchesTheSpecifiedFiveAndTwoMinutes() {
        protection.protect(sessionID: sessionID, triggerDate: trigger, origin: .manual)
        let event = index.activeEvents(forSession: sessionID).first!
        XCTAssertEqual(event.windowStart.timeIntervalSince(trigger), -300, accuracy: 0.001)
        XCTAssertEqual(event.windowEnd.timeIntervalSince(trigger), 120, accuracy: 0.001)
    }
}
