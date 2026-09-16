import AVFoundation
import XCTest
@testable import Dashcam

/// Whether filming the road is allowed to silence the car.
///
/// Reported from CarPlay: launching Spotify while Dashcam was running froze the video, and
/// the reverse — starting a drive — stopped the music. The app had never configured its
/// audio session at all, so `AVCaptureSession` did it, and the category it picks for a
/// microphone input takes the session away from whatever else is playing.
///
/// A dashcam that silences the car to film the road has misunderstood which of the two the
/// driver came for.
final class AudioSessionPolicyTests: XCTestCase {

    /// The assertion this file exists for.
    func testTheMusicKeepsPlayingWhileADriveIsFilmed() {
        let configuration = AudioSessionPolicy.configuration(recordsAudio: true)
        XCTAssertTrue(
            AudioSessionPolicy.leavesOtherAudioPlaying(configuration),
            "mixWithOthers is the whole point: without it, starting a drive stops the car's music"
        )
    }

    /// A drive filmed without sound needs no microphone and therefore no category. Leaving
    /// the session alone is strictly better than claiming it politely — the only thing a
    /// claim can do here is take something from another app.
    func testAppSilentMeansTheSessionIsNotTouchedAtAll() {
        XCTAssertNil(AudioSessionPolicy.configuration(recordsAudio: false))
        XCTAssertTrue(AudioSessionPolicy.leavesOtherAudioPlaying(nil))
    }

    /// Recording needs both directions — the microphone in, and whatever the session is
    /// mixed with staying audible — so `.playAndRecord` rather than `.record`.
    func testRecordingAsksForTheRightCategoryAndMode() {
        let configuration = try? XCTUnwrap(AudioSessionPolicy.configuration(recordsAudio: true))
        XCTAssertEqual(configuration?.category, .playAndRecord)
        XCTAssertEqual(configuration?.mode, .videoRecording)
    }

    /// The car's own route arrives over Bluetooth, CarPlay included. A `playAndRecord`
    /// session without these can drag playback back to the phone's speaker — which, from
    /// the driver's seat, is the same complaint in a different form.
    func testTheCarRouteStaysAvailable() {
        let options = AudioSessionPolicy.configuration(recordsAudio: true)?.options ?? []
        XCTAssertTrue(options.contains(.allowBluetooth))
        XCTAssertTrue(options.contains(.allowBluetoothA2DP))
    }
}
