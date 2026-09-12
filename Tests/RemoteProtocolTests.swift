import XCTest
@testable import Dashcam

/// The wrist remote speaks through dictionaries, which is a format with no compiler
/// behind it: the only thing keeping the watch and the phone in agreement is that both
/// compile this file. These tests hold the round trip.
final class RemoteProtocolTests: XCTestCase {
    func testEveryCommandSurvivesTheRoundTrip() {
        for command in [RemoteCommand.status, .start, .stop, .protect] {
            XCTAssertEqual(RemoteCommand(payload: command.payload), command)
        }
    }

    func testAnUnknownMessageIsRefusedRatherThanGuessed() {
        XCTAssertNil(RemoteCommand(payload: [:]))
        XCTAssertNil(RemoteCommand(payload: ["command": "selfDestruct"]))
        XCTAssertNil(RemoteCommand(payload: ["kommand": "start"]))
    }

    func testTheStateSurvivesTheRoundTrip() {
        let state = RemoteState(isRecording: true, elapsed: 3_725, protectedCount: 2)
        let decoded = RemoteState(payload: state.payload)
        XCTAssertEqual(decoded, state)
    }

    /// A reply missing the one field that matters is not a state at all — better no
    /// update than a remote that decides on its own that nothing is recording.
    func testAStateWithoutItsRecordingFlagIsRefused() {
        XCTAssertNil(RemoteState(payload: ["elapsed": 12.0]))
    }

    /// Missing extras take zero rather than refusing the whole message: a phone from an
    /// older version still reports whether it is recording, and that is the useful half.
    func testMissingExtrasFallBackToZero() {
        let decoded = RemoteState(payload: ["isRecording": true])
        XCTAssertEqual(decoded?.elapsed, 0)
        XCTAssertEqual(decoded?.protectedCount, 0)
    }

    func testElapsedReadsAsAClockOnTheWrist() {
        XCTAssertEqual(RemoteState(isRecording: true, elapsed: 59, protectedCount: 0).elapsedText, "00:59")
        XCTAssertEqual(RemoteState(isRecording: true, elapsed: 605, protectedCount: 0).elapsedText, "10:05")
        XCTAssertEqual(RemoteState(isRecording: true, elapsed: 3_725, protectedCount: 0).elapsedText, "1:02:05")
    }
}
