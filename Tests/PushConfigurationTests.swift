import XCTest
@testable import Dashcam

/// Whether this build can be pushed to at all.
///
/// The SDK is configuration-gated: with no `ONESIGNAL_APP_ID` in the xcconfig, OneSignal is
/// never initialised, no token is requested and nothing leaves the device. That gate is the
/// right default — and it is also a perfect way to ship a build that looks push-capable and
/// silently is not, because the value travels through an xcconfig, an Info.plist
/// substitution and a bundle read before anyone finds out.
@MainActor
final class PushConfigurationTests: XCTestCase {
    func testTheBuildCarriesItsOneSignalAppID() {
        guard let value = AppConfiguration.load().oneSignalAppID else {
            return XCTFail("no OneSignal id reached the bundle — push is inert")
        }
        // A UUID, whole. The xcconfig substitution is where a value gets silently truncated:
        // a `//` in an xcconfig cuts everything after it, and a placeholder left in place
        // reads as perfectly valid configuration.
        XCTAssertEqual(value.count, 36, "the id looks cut or replaced: \(value)")
        XCTAssertFalse(value.contains("TODO"), "the placeholder is still there")
    }

    /// The manager decides what it decides from that value alone, so it is worth pinning the
    /// two ends together rather than trusting the read.
    func testTheManagerReportsPushAsConfigured() {
        let manager = NotificationManager(
            configuration: AppConfiguration.load(),
            defaults: UserDefaults(suiteName: "push.tests")!
        )
        XCTAssertTrue(manager.isPushConfigured)
    }
}
