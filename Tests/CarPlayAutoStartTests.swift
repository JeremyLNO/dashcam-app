import AVFoundation
import XCTest
@testable import Dashcam

/// Auto-start on CarPlay: what the app can decide, tested without a car.
final class CarPlayAutoStartTests: XCTestCase {
    // MARK: Route detection

    func testACarAudioPortMeansCarPlay() {
        XCTAssertTrue(CarPlayConnectionMonitor.isCarPlay(portTypes: [.carAudio]))
        XCTAssertTrue(CarPlayConnectionMonitor.isCarPlay(portTypes: [.builtInSpeaker, .carAudio]))
    }

    /// Bluetooth to a car stereo is not CarPlay, and neither is a wired headset. Treating
    /// either as a car would start recording in someone's pocket.
    func testOtherRoutesAreNotCarPlay() {
        XCTAssertFalse(CarPlayConnectionMonitor.isCarPlay(portTypes: [.bluetoothA2DP]))
        XCTAssertFalse(CarPlayConnectionMonitor.isCarPlay(portTypes: [.bluetoothHFP]))
        XCTAssertFalse(CarPlayConnectionMonitor.isCarPlay(portTypes: [.headphones]))
        XCTAssertFalse(CarPlayConnectionMonitor.isCarPlay(portTypes: [.builtInSpeaker]))
        XCTAssertFalse(CarPlayConnectionMonitor.isCarPlay(portTypes: []))
    }

    // MARK: The auto-start decision

    func testItStartsWhenEnabledIdleAndReady() {
        XCTAssertTrue(CarPlayConnectionMonitor.shouldAutoStart(
            isEnabled: true, isAlreadyRecording: false, isCameraReady: true))
    }

    func testItDoesNothingWhenTheSettingIsOff() {
        XCTAssertFalse(CarPlayConnectionMonitor.shouldAutoStart(
            isEnabled: false, isAlreadyRecording: false, isCameraReady: true))
    }

    /// Connecting mid-drive must not restart a recording already in progress — that would
    /// cut the drive in two for no reason.
    func testItDoesNotRestartAnActiveRecording() {
        XCTAssertFalse(CarPlayConnectionMonitor.shouldAutoStart(
            isEnabled: true, isAlreadyRecording: true, isCameraReady: true))
    }

    /// No usable camera means starting would only produce an error alert at the exact
    /// moment the driver is pulling away.
    func testItStaysSilentWithNoCamera() {
        XCTAssertFalse(CarPlayConnectionMonitor.shouldAutoStart(
            isEnabled: true, isAlreadyRecording: false, isCameraReady: false))
    }

    func testTheSettingIsOffByDefault() {
        XCTAssertFalse(RecordingSettings().startOnCarPlayConnect)
    }
}
