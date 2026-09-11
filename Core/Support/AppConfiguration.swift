import Foundation

/// Everything the app needs to know that is decided outside Swift: product ids, URLs,
/// the App Store id, the push app id. All of it comes from `Info.plist`, which is filled
/// from `Config/*.xcconfig` at build time.
///
/// Nothing here has a hardcoded fallback that could ship silently wrong — a missing or
/// placeholder value is reported as absent so the feature depending on it stays off.
struct AppConfiguration: Sendable {
    let subscriptionGroupID: String
    let monthlyProductID: String
    let quarterlyProductID: String
    let yearlyProductID: String
    let supportURL: URL?
    let brandURL: URL?
    let termsURL: URL?
    let privacyURL: URL?
    let appStoreAppID: String?
    let oneSignalAppID: String?

    /// Ordered the way the paywall lists them.
    var productIDs: [String] { [monthlyProductID, quarterlyProductID, yearlyProductID] }

    var reviewURL: URL? {
        guard let id = appStoreAppID else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)?action=write-review")
    }

    var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    /// iTunes lookup endpoint used by the "update available" check. Nil until the app
    /// actually has a store record.
    var versionLookupURL: URL? {
        guard let id = appStoreAppID else { return nil }
        return URL(string: "https://itunes.apple.com/lookup?id=\(id)")
    }

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        let dict = bundle.object(forInfoDictionaryKey: "DashcamConfiguration") as? [String: Any] ?? [:]

        func string(_ key: String) -> String {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        /// Empty, or an unreplaced build-setting placeholder, both mean "not configured".
        func optional(_ key: String) -> String? {
            let value = string(key)
            guard !value.isEmpty, !value.hasPrefix("$("), value != "0000000000" else { return nil }
            return value
        }
        func url(_ key: String) -> URL? {
            guard let value = optional(key) else { return nil }
            return URL(string: value)
        }

        return AppConfiguration(
            subscriptionGroupID: string("SubscriptionGroupID"),
            monthlyProductID: string("MonthlyProductID"),
            quarterlyProductID: string("QuarterlyProductID"),
            yearlyProductID: string("YearlyProductID"),
            supportURL: url("SupportURL"),
            brandURL: url("BrandURL"),
            termsURL: url("TermsURL"),
            privacyURL: url("PrivacyURL"),
            appStoreAppID: optional("AppStoreAppID"),
            oneSignalAppID: optional("OneSignalAppID")
        )
    }
}
