import XCTest
@testable import Dashcam

/// The commercial rule, in isolation from StoreKit.
///
/// It is stated once in `SubscriptionState.canExport` and nowhere else, so this is the
/// test that guards it.
final class SubscriptionStateTests: XCTestCase {
    func testExportIsLockedDuringTheFreeTrial() {
        var state = SubscriptionState()
        state.isDetermined = true
        state.hasActiveEntitlement = true
        state.isInIntroductoryOffer = true

        XCTAssertTrue(state.hasFullRecordingAccess, "recording is available during the trial")
        XCTAssertFalse(state.canExport, "export must stay locked until the trial converts")
    }

    func testExportUnlocksOnceThePaidPeriodStarts() {
        var state = SubscriptionState()
        state.isDetermined = true
        state.hasActiveEntitlement = true
        state.isInIntroductoryOffer = false

        XCTAssertTrue(state.canExport)
    }

    func testNoEntitlementMeansNoExportAndNoRecordingUnlock() {
        var state = SubscriptionState()
        state.isDetermined = true

        XCTAssertFalse(state.canExport)
        XCTAssertFalse(state.hasFullRecordingAccess)
    }

    /// An expired or revoked subscription cannot be rescued by the trial flag.
    func testTrialFlagAloneGrantsNothing() {
        var state = SubscriptionState()
        state.isDetermined = true
        state.hasActiveEntitlement = false
        state.isInIntroductoryOffer = true

        XCTAssertFalse(state.canExport)
    }

    func testUndeterminedStateIsNotTreatedAsSubscribed() {
        XCTAssertFalse(SubscriptionState.undetermined.isDetermined)
        XCTAssertFalse(SubscriptionState.undetermined.canExport)
    }

    func testPendingPurchaseDoesNotGrantAccess() {
        var state = SubscriptionState()
        state.isDetermined = true
        state.hasPendingTransaction = true

        XCTAssertFalse(state.canExport)
    }
}
