import XCTest
@testable import Dashcam

/// Settings have to survive an app update.
///
/// They did not: the synthesised `Codable` decoder throws on a key it does not find, and
/// the store answers a throw by starting from factory defaults. Adding one field to
/// `RecordingSettings` therefore wiped every preference on the next launch — quietly,
/// and only for people who already had the app. A driver reported it as "I turned
/// location on and it was off again".
final class SettingsDecodingTests: XCTestCase {
    /// A blob written by a build that knew nothing of the fields added since.
    private let legacyBlob = """
    {
      "quality": "high",
      "segmentDuration": 300,
      "recordAudio": false,
      "retention": "sevenDays",
      "storageLimit": "gb25",
      "autoStartOnLaunch": true,
      "discreetDelay": 60,
      "impactDetectionEnabled": false,
      "shockSensitivity": "high",
      "locationMetadataEnabled": true,
      "overlayEnabled": false,
      "overlayFields": 3,
      "frontCameraEnabled": false,
      "requireBiometricUnlock": true
    }
    """.data(using: .utf8)!

    func testAnOlderBlobKeepsEveryValueItCarried() throws {
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: legacyBlob)

        XCTAssertEqual(settings.quality, .high)
        XCTAssertEqual(settings.segmentDuration, .fiveMinutes)
        XCTAssertFalse(settings.recordAudio)
        XCTAssertEqual(settings.retention, .sevenDays)
        XCTAssertEqual(settings.storageLimit, .gb25)
        XCTAssertTrue(settings.autoStartOnLaunch)
        XCTAssertFalse(settings.impactDetectionEnabled)
        XCTAssertEqual(settings.shockSensitivity, .high)
        XCTAssertTrue(settings.locationMetadataEnabled, "the value the driver set must come back")
        XCTAssertFalse(settings.overlayEnabled)
        XCTAssertFalse(settings.frontCameraEnabled)
        XCTAssertTrue(settings.requireBiometricUnlock)
    }

    /// The fields that blob never heard of take their default, and nothing else moves.
    func testFieldsAddedSinceTakeTheirDefault() throws {
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: legacyBlob)
        let defaults = RecordingSettings()

        XCTAssertEqual(settings.autoExportProtected, defaults.autoExportProtected)
        XCTAssertEqual(settings.startOnCarPlayConnect, defaults.startOnCarPlayConnect)
        XCTAssertEqual(settings.harshBrakingDetectionEnabled, defaults.harshBrakingDetectionEnabled)
    }

    /// An empty object is the extreme case of the same thing: it must not throw.
    func testAnEmptyObjectDecodesToTheDefaults() throws {
        let settings = try JSONDecoder().decode(RecordingSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, RecordingSettings())
    }

    /// A round trip keeps everything, which is what makes the tolerant decoder safe to
    /// use for writing as well as reading.
    func testEncodingThenDecodingIsLossless() throws {
        var settings = RecordingSettings()
        settings.quality = .eco
        settings.recordAudio = false
        settings.autoExportProtected = true
        settings.overlayFields = [.date, .location]

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(RecordingSettings.self, from: data), settings)
    }

    /// The defaults a new driver gets. Audio, the cabin camera and both detectors are on;
    /// the automatic export and the biometric lock are not, because each of those writes
    /// or withholds something the driver never asked for.
    func testTheDefaultsANewInstallStartsFrom() {
        let defaults = RecordingSettings()
        XCTAssertTrue(defaults.recordAudio)
        XCTAssertTrue(defaults.frontCameraEnabled)
        XCTAssertTrue(defaults.impactDetectionEnabled)
        XCTAssertTrue(defaults.harshBrakingDetectionEnabled)
        XCTAssertTrue(defaults.locationMetadataEnabled)
        XCTAssertFalse(defaults.autoExportProtected)
        XCTAssertFalse(defaults.requireBiometricUnlock)
    }
}
