import CoreLocation
import XCTest
@testable import Dashcam

/// What the app does about location, given what the driver asked for and what iOS allows.
///
/// The case that forced this rule out into the open: **Allow Once**. The permission lapses
/// at the next launch while the setting still says the driver wants position, and the app
/// used to show "Off" and never ask again — the driver had turned GPS on, quit, and found
/// it off, with nothing explaining why.
final class LocationIntentTests: XCTestCase {
    private func decide(
        wants: Bool = true,
        auth: CLAuthorizationStatus = .authorizedWhenInUse,
        recording: Bool = false,
        updating: Bool = false,
        foreground: Bool = true
    ) -> LocationIntent {
        LocationIntent.decide(
            wantsLocation: wants, authorization: auth,
            isRecording: recording, isUpdating: updating, isForeground: foreground
        )
    }

    /// The reported defect, in one assertion.
    func testALapsedOneTimePermissionIsAskedForAgain() {
        XCTAssertEqual(decide(auth: .notDetermined), .request)
    }

    func testNothingIsAskedWhileTheAppIsInTheBackground() {
        XCTAssertEqual(decide(auth: .notDetermined, foreground: false), .none,
                       "a prompt nobody sees is a prompt nobody answers")
    }

    func testAGrantedPermissionKeepsAFixWarmInTheForeground() {
        XCTAssertEqual(decide(), .start)
        XCTAssertEqual(decide(updating: true), .none, "already running")
    }

    /// A recording outranks the foreground rule: the drive keeps its fixes even as the
    /// screen goes elsewhere.
    func testARecordingKeepsLocationRunning() {
        XCTAssertEqual(decide(recording: true, updating: true, foreground: false), .none)
        XCTAssertEqual(decide(recording: true, updating: false, foreground: false), .start)
    }

    /// Leaving the app with nothing being recorded is the one moment to let go of the GPS.
    func testLeavingTheAppStopsTheUpdatesWhenNothingIsRecording() {
        XCTAssertEqual(decide(updating: true, foreground: false), .stop)
        XCTAssertEqual(decide(updating: false, foreground: false), .none)
    }

    func testTurningTheSettingOffStopsWhateverIsRunning() {
        XCTAssertEqual(decide(wants: false, updating: true), .stop)
        XCTAssertEqual(decide(wants: false, updating: false), .none)
    }

    /// A refusal is not a question to ask again: the app offers the way to Settings on the
    /// recording screen instead of re-prompting into a wall.
    func testARefusedPermissionIsNeverAskedAgain() {
        XCTAssertEqual(decide(auth: .denied), .none)
        XCTAssertEqual(decide(auth: .restricted), .none)
        XCTAssertEqual(decide(auth: .denied, updating: true), .stop)
    }

    func testAlwaysAuthorisedBehavesLikeWhenInUse() {
        XCTAssertEqual(decide(auth: .authorizedAlways), .start)
    }
}
