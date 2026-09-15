import CoreLocation
import XCTest
@testable import Dashcam

/// Asking iOS to raise *When In Use* to *Always* — a prompt with exactly one shot.
///
/// Every way of getting this wrong is silent. Asking before the first grant raises nothing.
/// Asking a second time raises nothing. Asking without the Info.plist key raises nothing.
/// In all three cases the app looks like it asked and the driver sees no prompt, which
/// reads as a refusal they never gave.
final class LocationUpgradeTests: XCTestCase {
    func testTheUpgradeIsOnlyAskedFromWhenInUse() {
        XCTAssertEqual(
            LocationUpgrade.decide(authorization: .authorizedWhenInUse, wantsLocation: true, hasAlreadyAsked: false),
            .ask
        )
    }

    /// `.notDetermined` belongs to the first prompt. Asking for Always there shows nothing
    /// at all — and would burn the one shot for nobody.
    func testNothingIsAskedBeforeTheFirstGrant() {
        XCTAssertEqual(
            LocationUpgrade.decide(authorization: .notDetermined, wantsLocation: true, hasAlreadyAsked: false),
            .none
        )
    }

    func testNothingIsAskedWhenItIsAlreadyGrantedOrRefused() {
        for status in [CLAuthorizationStatus.authorizedAlways, .denied, .restricted] {
            XCTAssertEqual(
                LocationUpgrade.decide(authorization: status, wantsLocation: true, hasAlreadyAsked: false),
                .none,
                "\(status) has nothing left to ask for"
            )
        }
    }

    /// The one shot is spent for the life of the install. A second call is not a second
    /// prompt, it is a no-op — so the app must not pretend otherwise.
    func testTheSecondAskIsNotAnAsk() {
        XCTAssertEqual(
            LocationUpgrade.decide(authorization: .authorizedWhenInUse, wantsLocation: true, hasAlreadyAsked: true),
            .none
        )
    }

    /// A driver who turned position off is not asked to widen a permission they do not want.
    func testNothingIsAskedWhenPositionIsTurnedOff() {
        XCTAssertEqual(
            LocationUpgrade.decide(authorization: .authorizedWhenInUse, wantsLocation: false, hasAlreadyAsked: false),
            .none
        )
    }

    /// The row stays visible while the state still allows the prompt — including right after
    /// a tap, before the system has been answered. A control that vanishes under the thumb
    /// reads as a bug.
    func testTheRowIsOfferedWhileTheStateAllowsIt() {
        XCTAssertTrue(LocationUpgrade.isOfferable(authorization: .authorizedWhenInUse, wantsLocation: true))
        XCTAssertFalse(LocationUpgrade.isOfferable(authorization: .authorizedAlways, wantsLocation: true))
        XCTAssertFalse(LocationUpgrade.isOfferable(authorization: .notDetermined, wantsLocation: true))
        XCTAssertFalse(LocationUpgrade.isOfferable(authorization: .authorizedWhenInUse, wantsLocation: false))
    }

    /// The prompt does not exist without its Info.plist key, and nothing at runtime says so.
    func testTheUsageDescriptionShipsWithTheApp() throws {
        let description = Bundle.main.object(
            forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription"
        ) as? String
        let value = try XCTUnwrap(description, "no Always usage string — the prompt would never appear")
        XCTAssertFalse(value.isEmpty)
    }
}
