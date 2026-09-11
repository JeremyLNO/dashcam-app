import Foundation

/// What the store says about this Apple ID, reduced to the three questions the app
/// actually asks. Deliberately a value type: `SubscriptionManager` republishes a whole
/// new state rather than mutating flags one at a time.
struct SubscriptionState: Equatable, Sendable {
    /// A subscription in this group is currently giving the user access.
    var hasActiveEntitlement: Bool = false
    /// That access is currently being paid for by the introductory (free trial) offer.
    var isInIntroductoryOffer: Bool = false
    /// The product id backing the current entitlement, if any.
    var activeProductID: String?
    var expirationDate: Date?
    /// True until the first StoreKit sweep finishes, so the UI can avoid flashing a
    /// paywall at a subscriber during launch.
    var isDetermined: Bool = false
    /// A purchase is waiting on Ask to Buy / SCA.
    var hasPendingTransaction: Bool = false

    /// THE product rule, in one place.
    ///
    /// The 3-day introductory offer is a *try before you buy* of the recording features
    /// only. Export stays locked until the trial converts and the user is genuinely
    /// paying — an active entitlement is not on its own enough.
    var canExport: Bool {
        hasActiveEntitlement && !isInIntroductoryOffer
    }

    /// Everything other than export is free during the trial.
    var hasFullRecordingAccess: Bool { hasActiveEntitlement }

    static let undetermined = SubscriptionState()
}
