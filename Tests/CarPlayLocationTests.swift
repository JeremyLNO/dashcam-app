import CoreLocation
import SwiftData
import XCTest
@testable import Dashcam

/// Whether a drive begun from the car's screen carries its positions — at its first second
/// and at its last.
///
/// The question is worth asking because CarPlay is a *second scene*: the driver taps a
/// button that is not the app's, on a screen the app does not own. Every other origin —
/// the big red button, the Watch, a Shortcut, the automatic start on connect — goes through
/// `RecordingManager.start()`, and so does this one; the GPS is switched on inside
/// `startSensors()` and off inside `stopSensors()`, for all of them alike. **That funnel is
/// the guarantee**, and what these tests pin is the half that can break silently: what
/// happens to the fixes already collected when the drive ends.
///
/// A position that is inserted but never saved is indistinguishable, in the app, from a
/// position that was recorded — right up to the next launch, where the drive has a route
/// and no coordinates.
@MainActor
final class CarPlayLocationTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
    }

    override func tearDownWithError() throws {
        index = nil
        container = nil
    }

    private func fix(_ offset: TimeInterval, latitude: Double, longitude: Double) -> (Date, Double, Double) {
        (start.addingTimeInterval(offset), latitude, longitude)
    }

    /// Reads through a context of its own — **not** `SessionIndex`, which hands back the
    /// container's `mainContext` and would therefore be the very context that did the
    /// inserting. Fetching from there proves nothing: an unsaved object is sitting right
    /// in front of the reader, and the test passes whether or not anything was written.
    private func persistedSamples(_ sessionID: UUID) -> [LocationSample] {
        let reader = ModelContext(container)
        let descriptor = FetchDescriptor<LocationSample>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? reader.fetch(descriptor)) ?? []
    }

    private func append(_ sample: (Date, Double, Double), to sessionID: UUID) {
        index.appendLocationSample(
            sessionID: sessionID, timestamp: sample.0,
            latitude: sample.1, longitude: sample.2,
            speed: 25, course: 90, altitude: 40, accuracy: 5
        )
    }

    /// The first fix of a drive arrives seconds after the session row is created. It has to
    /// land on *that* session, not float free: a sample without its drive is a row nobody
    /// ever reads.
    func testTheFirstFixIsAttachedToTheDriveThatJustStarted() throws {
        let session = index.beginSession(startedAt: start, quality: .standard)
        append(fix(2, latitude: 48.8566, longitude: 2.3522), to: session.id)
        index.save()

        let samples = persistedSamples(session.id)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.latitude ?? 0, 48.8566, accuracy: 0.0001)
    }

    /// The sequence `RecordingManager.stop()` actually performs: the sensors are cut and the
    /// context saved, the writers are closed, then the session is ended. The fixes gathered
    /// during the drive have to survive all three steps.
    func testEveryFixSurvivesTheEndOfADrive() throws {
        let session = index.beginSession(startedAt: start, quality: .standard)
        for second in stride(from: 2.0, through: 20.0, by: 2.0) {
            append(fix(second, latitude: 48.8566 + second / 10_000, longitude: 2.3522), to: session.id)
        }

        // stopSensors()
        index.save()
        // endSession(), after the writers have closed
        index.endSession(id: session.id, endedAt: start.addingTimeInterval(25))

        let samples = persistedSamples(session.id)
        XCTAssertEqual(samples.count, 10, "a drive that ends must keep every position it collected")
        XCTAssertEqual(
            samples.last?.latitude ?? 0, 48.8566 + 20.0 / 10_000, accuracy: 0.0001,
            "the last fix is where the drive ended — it is the one an insurer looks at"
        )
    }

    /// A fix that arrives *between* the sensors being cut and the session being closed still
    /// belongs to the drive: `currentSessionID` is only cleared after `endSession`, so the
    /// handler keeps writing, and the save inside `endSession` is what persists it.
    func testAFixArrivingDuringTheStopSequenceIsStillKept() throws {
        let session = index.beginSession(startedAt: start, quality: .standard)
        append(fix(2, latitude: 48.8566, longitude: 2.3522), to: session.id)
        index.save()

        // The late one, after the sensors were asked to stop.
        append(fix(4, latitude: 48.8600, longitude: 2.3600), to: session.id)
        index.endSession(id: session.id, endedAt: start.addingTimeInterval(5))

        let samples = persistedSamples(session.id)
        XCTAssertEqual(samples.count, 2, "the fix that arrived during the teardown was dropped")
        XCTAssertEqual(samples.last?.longitude ?? 0, 2.3600, accuracy: 0.0001)
    }

    /// Positions are inserted every two seconds, and a segment being finalised saves the
    /// context explicitly. Autosave is on as well, so this is a second belt rather than the
    /// only one — but it is the one with a bound: a drive killed mid-way loses at most the
    /// segment in progress, the same window the footage itself has.
    func testASegmentBoundarySavesThePositionsCollectedSoFar() throws {
        let session = index.beginSession(startedAt: start, quality: .standard)
        for second in stride(from: 2.0, through: 8.0, by: 2.0) {
            append(fix(second, latitude: 48.8566, longitude: 2.3522), to: session.id)
        }

        // No explicit save here: finalising a segment is what flushes the context.
        TestSupport.addSegment(to: index, sessionID: session.id, segmentIndex: 0, start: start)
        defer { TestSupport.removeSessionFiles(session.id) }

        XCTAssertEqual(
            persistedSamples(session.id).count, 4,
            "a segment boundary has to flush the positions with it"
        )
    }

    // MARK: - The rule behind the funnel

    /// The decision that governs a drive started from the car while the phone's own screen
    /// is not the one being looked at. Recording outranks everything: the GPS starts.
    func testADriveStartedFromTheCarKeepsItsLocationWhateverTheAppIsDoing() {
        XCTAssertEqual(
            LocationIntent.decide(
                wantsLocation: true, authorization: .authorizedWhenInUse,
                isRecording: true, isUpdating: false, isForeground: false
            ),
            .start,
            "a drive is a drive whether or not the phone screen is the one in front of the driver"
        )
    }

    /// And the mirror: once that drive ends, nothing justifies holding the receiver open.
    func testTheEndOfADriveReleasesTheReceiver() {
        XCTAssertEqual(
            LocationIntent.decide(
                wantsLocation: true, authorization: .authorizedWhenInUse,
                isRecording: false, isUpdating: true, isForeground: false
            ),
            .stop
        )
    }
}
