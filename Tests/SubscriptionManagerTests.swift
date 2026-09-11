import StoreKit
import StoreKitTest
import XCTest
@testable import Dashcam

/// End-to-end subscription behaviour against a real StoreKit engine.
///
/// `SKTestSession` loads `Dashcam.storekit` from the test bundle, so these tests do not
/// depend on the scheme's StoreKit configuration being wired up — they run the same way
/// from Xcode and from `xcodebuild` on a machine that has never opened the project.
@MainActor
final class SubscriptionManagerTests: XCTestCase {
    private var session: SKTestSession!
    private var manager: SubscriptionManager!
    private var configuration: AppConfiguration!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle(for: SubscriptionManagerTests.self).url(forResource: "Dashcam", withExtension: "storekit"),
            "Dashcam.storekit is not in the test bundle"
        )
        session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        // `resetToDefaultState()` never returns under `xcodebuild test`; clearing the
        // transactions is what these tests actually need anyway.
        session.clearTransactions()
        session.storefront = "USA"

        // StoreKit Testing does not engage on the iOS 26.x simulator runtimes: the session
        // is created but stays inert (an empty storefront is the tell, and every product
        // query comes back empty). Skipping is honest; silently passing would not be.
        // See docs/DEVICE-TESTING.md — run these against an iOS 18.6 simulator.
        try XCTSkipIf(
            session.storefront.isEmpty,
            "StoreKit Testing is unavailable on this simulator runtime; run on iOS 18.6"
        )

        configuration = AppConfiguration.load()
        manager = SubscriptionManager(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session?.clearTransactions()
        session = nil
    }

    // MARK: Products

    func testAllThreePlansLoadWithStoreKitPrices() async {
        await manager.loadProducts()

        XCTAssertEqual(manager.plans.count, 3)
        XCTAssertEqual(manager.plans.map(\.period), [.monthly, .quarterly, .yearly],
                       "the paywall lists monthly, quarterly, yearly in that order")
        for plan in manager.plans {
            XCTAssertFalse(plan.displayPrice.isEmpty, "\(plan.id) has no price")
            // The price must come from StoreKit, never from a literal in the app.
            XCTAssertTrue(plan.displayPrice.rangeOfCharacter(from: .decimalDigits) != nil)
        }
    }

    func testEveryPlanCarriesTheThreeDayFreeTrial() async {
        await manager.loadProducts()

        for plan in manager.plans {
            guard let offer = plan.introductoryOffer else {
                XCTFail("\(plan.id) has no introductory offer")
                continue
            }
            XCTAssertEqual(offer.paymentMode, .freeTrial)
            XCTAssertEqual(offer.period.unit, .day)
            XCTAssertEqual(offer.period.value, 3)
        }
    }

    /// The group id used for status and eligibility queries has to be StoreKit's own
    /// numeric id, read off a product — not the reference name in the xcconfig.
    func testSubscriptionGroupIsResolvedFromTheLoadedProducts() async {
        await manager.loadProducts()
        let groupIDs = Set(manager.plans.compactMap { $0.product.subscription?.subscriptionGroupID })
        XCTAssertEqual(groupIDs.count, 1, "all three plans belong to one group")
    }

    // MARK: The export rule

    func testNothingIsEntitledBeforeAnyPurchase() async {
        await manager.refreshEntitlement()

        XCTAssertTrue(manager.state.isDetermined)
        XCTAssertFalse(manager.state.hasActiveEntitlement)
        XCTAssertFalse(manager.state.canExport)
    }

    /// The rule the whole product hangs on: subscribing while eligible starts the free
    /// trial, which grants recording but **not** export.
    func testBuyingWhileEligibleStartsTheTrialAndKeepsExportLocked() async throws {
        await manager.loadProducts()
        let yearly = try XCTUnwrap(manager.plans.first { $0.period == .yearly })

        try await session.buyProduct(productIdentifier: yearly.id)
        await manager.refreshEntitlement()

        XCTAssertTrue(manager.state.hasActiveEntitlement)
        XCTAssertTrue(manager.state.isInIntroductoryOffer, "the purchase used the intro offer")
        XCTAssertTrue(manager.state.hasFullRecordingAccess, "recording works during the trial")
        XCTAssertFalse(manager.state.canExport, "export stays locked for the whole trial")
    }

    /// The other half of the rule — export opening once the user is genuinely paying —
    /// cannot be produced here.
    ///
    /// `SKTestSession.buyProduct` always applies the eligible introductory offer, and
    /// neither expiring the subscription nor switching to another product in the group
    /// consumes that eligibility the way the real App Store does. So there is no way to
    /// manufacture a *paid, non-introductory* transaction in a local StoreKit session.
    ///
    /// What that leaves:
    ///   * the mapping itself is covered exhaustively by `SubscriptionStateTests`, which
    ///     exercises `canExport` for every combination of entitlement and offer state;
    ///   * the conversion is verified against the real thing in Sandbox — see
    ///     `docs/DEVICE-TESTING.md`, section 8.
    ///
    /// This test exists to keep that gap visible rather than silent.
    func testConversionToPaidIsVerifiedInSandboxNotHere() async throws {
        await manager.loadProducts()
        let monthly = try XCTUnwrap(manager.plans.first { $0.period == .monthly })

        try await session.buyProduct(productIdentifier: monthly.id)
        try session.expireSubscription(productIdentifier: monthly.id)
        try await session.buyProduct(productIdentifier: monthly.id)
        await manager.refreshEntitlement()

        try XCTSkipIf(
            manager.state.isInIntroductoryOffer,
            "StoreKit Testing re-applies the introductory offer; the paid path is a Sandbox check"
        )
        // If a future StoreKit Testing stops re-applying the offer, this becomes a real
        // assertion on its own.
        XCTAssertTrue(manager.state.canExport)
    }

    func testExpiredSubscriptionsGrantNothing() async throws {
        await manager.loadProducts()
        let monthly = try XCTUnwrap(manager.plans.first { $0.period == .monthly })

        try await session.buyProduct(productIdentifier: monthly.id)
        await manager.refreshEntitlement()
        XCTAssertTrue(manager.state.hasActiveEntitlement)

        // Expire everything the way a lapsed subscription would.
        session.clearTransactions()
        await manager.refreshEntitlement()

        XCTAssertFalse(manager.state.hasActiveEntitlement)
        XCTAssertFalse(manager.state.canExport)
    }

    /// A refunded transaction still appears in the entitlement stream; it must not grant
    /// access.
    func testRefundedTransactionsAreIgnored() async throws {
        await manager.loadProducts()
        let monthly = try XCTUnwrap(manager.plans.first { $0.period == .monthly })

        try await session.buyProduct(productIdentifier: monthly.id)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try await session.refundTransaction(identifier: transaction.identifier)
        await manager.refreshEntitlement()

        XCTAssertFalse(manager.state.canExport)
    }

    func testPurchasingThroughTheManagerReportsSuccess() async throws {
        await manager.loadProducts()
        let quarterly = try XCTUnwrap(manager.plans.first { $0.period == .quarterly })

        let outcome = await manager.purchase(quarterly)

        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(manager.state.hasActiveEntitlement)
        XCTAssertEqual(manager.state.activeProductID, quarterly.id)
    }
}
