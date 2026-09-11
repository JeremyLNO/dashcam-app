import Foundation
import StoreKit

/// One purchasable plan, resolved from StoreKit. Prices are always `product.displayPrice`
/// — nothing about money is ever written in Swift or in a plist.
struct SubscriptionPlan: Identifiable, Equatable, Sendable {
    let id: String
    let product: Product
    let period: Period

    enum Period: String, Sendable {
        case monthly, quarterly, yearly, unknown

        var titleKey: String {
            switch self {
            case .monthly: return "plan.monthly"
            case .quarterly: return "plan.quarterly"
            case .yearly: return "plan.yearly"
            case .unknown: return "plan.unknown"
            }
        }
    }

    var displayPrice: String { product.displayPrice }

    /// The introductory offer attached to this product, if any and if this Apple ID is
    /// still eligible. Rendered as "3 days free, then <price>".
    var introductoryOffer: Product.SubscriptionOffer? { product.subscription?.introductoryOffer }

    static func == (lhs: SubscriptionPlan, rhs: SubscriptionPlan) -> Bool { lhs.id == rhs.id }
}

enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
    case failed(String)
}

/// Single source of truth for entitlement.
///
/// The product rule this class exists to enforce: **during the 3-day introductory offer,
/// export stays locked.** The trial is a free look at the dashcam itself; getting footage
/// *out* of the app is what the subscription is for. `SubscriptionState.canExport`
/// implements it, and nothing else in the app is allowed to make that judgement.
@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var state: SubscriptionState = .undetermined
    @Published private(set) var plans: [SubscriptionPlan] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isEligibleForIntroductoryOffer = false
    @Published private(set) var lastError: String?

    private let configuration: AppConfiguration
    private var updatesTask: Task<Void, Never>?
    /// StoreKit identifies a subscription group by a numeric id that App Store Connect
    /// assigns — not by the human-readable reference name in our xcconfig. It is read
    /// back off a loaded product, which is the only place it is authoritative.
    private var resolvedGroupID: String?

    private var effectiveGroupID: String? {
        if let resolvedGroupID, !resolvedGroupID.isEmpty { return resolvedGroupID }
        return configuration.subscriptionGroupID.isEmpty ? nil : configuration.subscriptionGroupID
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    deinit {
        updatesTask?.cancel()
    }

    /// Starts the transaction listener before anything else, so a purchase that completes
    /// outside the app (Ask to Buy approval, a renewal) is never missed.
    func bootstrap() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlement()
        }
    }

    // MARK: - Products

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: configuration.productIDs)
            plans = products
                .map { SubscriptionPlan(id: $0.id, product: $0, period: Self.period(for: $0, configuration: configuration)) }
                .sorted { Self.order($0.period) < Self.order($1.period) }

            resolvedGroupID = products.compactMap { $0.subscription?.subscriptionGroupID }.first
            if let groupID = effectiveGroupID {
                isEligibleForIntroductoryOffer = await Product.SubscriptionInfo
                    .isEligibleForIntroOffer(for: groupID)
            }
            lastError = nil
        } catch {
            // No products means no store connection or a misconfigured App Store Connect
            // record. Surface it rather than showing an empty paywall.
            lastError = error.localizedDescription
            Log.store.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Purchase / restore

    func purchase(_ plan: SubscriptionPlan) async -> PurchaseOutcome {
        do {
            let result = try await plan.product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlement()
                    return .purchased
                case .unverified(_, let error):
                    lastError = error.localizedDescription
                    return .failed(error.localizedDescription)
                }
            case .pending:
                state.hasPendingTransaction = true
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed("unknown")
            }
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// "Restore Purchases". `AppStore.sync()` re-authenticates and pulls the receipt
    /// again, which is what recovers a subscription after a device restore or an Apple ID
    /// change.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            // A cancelled sign-in sheet lands here; not worth alarming the user about.
            Log.store.info("Restore ended: \(error.localizedDescription, privacy: .public)")
        }
        await refreshEntitlement()
    }

    // MARK: - Entitlement

    /// Rebuilds the whole state from StoreKit. Handles renewals, expiry, revocation,
    /// refunds and grace periods by simply asking again rather than tracking deltas.
    func refreshEntitlement() async {
        var newState = SubscriptionState()
        newState.isDetermined = true
        newState.hasPendingTransaction = state.hasPendingTransaction

        let ownedIDs = Set(configuration.productIDs)

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ownedIDs.contains(transaction.productID) else { continue }
            // A refunded or revoked transaction still shows up; it must not grant access.
            guard transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }

            newState.hasActiveEntitlement = true
            newState.activeProductID = transaction.productID
            newState.expirationDate = transaction.expirationDate
            newState.isInIntroductoryOffer = Self.isIntroductory(transaction)
        }

        // Cross-check against the subscription group status: it is the only place that
        // reports grace period and billing retry, both of which keep access alive.
        if let groupID = effectiveGroupID,
           let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
            for status in statuses {
                guard case .verified(let renewalInfo) = status.renewalInfo,
                      case .verified(let transaction) = status.transaction,
                      ownedIDs.contains(transaction.productID)
                else { continue }

                switch status.state {
                case .subscribed, .inGracePeriod, .inBillingRetryPeriod:
                    newState.hasActiveEntitlement = true
                    newState.activeProductID = transaction.productID
                    newState.expirationDate = transaction.expirationDate
                    if Self.isIntroductory(transaction) { newState.isInIntroductoryOffer = true }
                    _ = renewalInfo
                case .expired, .revoked:
                    continue
                default:
                    continue
                }
            }
        }

        if !newState.hasActiveEntitlement { newState.hasPendingTransaction = false }
        state = newState
        if let groupID = effectiveGroupID {
            isEligibleForIntroductoryOffer = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)
        } else {
            isEligibleForIntroductoryOffer = false
        }

        Log.store.info("Entitlement: active=\(newState.hasActiveEntitlement) trial=\(newState.isInIntroductoryOffer) export=\(newState.canExport)")
    }

    // MARK: - Helpers

    /// Is this entitlement currently being paid for by the introductory offer?
    ///
    /// `Transaction.offer` replaced `offerType` in iOS 17.2; the deployment target is
    /// 17.0, so both paths have to exist.
    private static func isIntroductory(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, *) {
            return transaction.offer?.type == .introductory
        } else {
            return transaction.offerType == .introductory
        }
    }

    private static func period(for product: Product, configuration: AppConfiguration) -> SubscriptionPlan.Period {
        switch product.id {
        case configuration.monthlyProductID: return .monthly
        case configuration.quarterlyProductID: return .quarterly
        case configuration.yearlyProductID: return .yearly
        default: break
        }
        // Fall back to what StoreKit says, so a renamed product id still lands in the
        // right row instead of disappearing off the paywall.
        guard let subscription = product.subscription else { return .unknown }
        switch (subscription.subscriptionPeriod.unit, subscription.subscriptionPeriod.value) {
        case (.month, 1): return .monthly
        case (.month, 3): return .quarterly
        case (.year, 1): return .yearly
        default: return .unknown
        }
    }

    private static func order(_ period: SubscriptionPlan.Period) -> Int {
        switch period {
        case .monthly: return 0
        case .quarterly: return 1
        case .yearly: return 2
        case .unknown: return 3
        }
    }
}

extension Product.SubscriptionOffer {
    /// "3 days" / "1 week" — the trial length, read from StoreKit rather than assumed.
    var localizedPeriodDescription: String {
        let value = period.value
        let unitKey: String
        switch period.unit {
        case .day: unitKey = value == 1 ? "period.day" : "period.days"
        case .week: unitKey = value == 1 ? "period.week" : "period.weeks"
        case .month: unitKey = value == 1 ? "period.month" : "period.months"
        case .year: unitKey = value == 1 ? "period.year" : "period.years"
        @unknown default: unitKey = "period.days"
        }
        return "\(value) \(L10n.t(unitKey))"
    }
}
