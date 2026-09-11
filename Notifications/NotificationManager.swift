import Foundation
import UIKit
import UserNotifications
#if canImport(OneSignalFramework)
import OneSignalFramework
#endif

/// Push and local notifications.
///
/// OneSignal is the push provider, but it is *configuration gated*: with no
/// `ONESIGNAL_APP_ID` in the xcconfig the SDK is never initialised, no device token is
/// requested and nothing is sent anywhere. That keeps the privacy promise honest for a
/// build that ships without push, and it keeps the app compiling whether or not the SPM
/// package is present.
@MainActor
final class NotificationManager: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isPushConfigured = false
    /// Set when the App Store has a newer version than the one running.
    @Published private(set) var availableUpdateVersion: String?

    private let configuration: AppConfiguration
    private let defaults: UserDefaults

    private enum Key {
        static let enabled = "notifications.enabled"
        static let lastUpdateCheck = "notifications.lastUpdateCheck"
        static let notifiedVersion = "notifications.notifiedVersion"
    }

    init(configuration: AppConfiguration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        self.isPushConfigured = configuration.oneSignalAppID != nil
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Called from the app delegate at launch. Does nothing at all unless push is both
    /// configured and enabled by the user.
    func bootstrap(launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) {
        refreshAuthorization()
        guard let appID = configuration.oneSignalAppID, isEnabled else { return }
        #if canImport(OneSignalFramework)
        OneSignal.initialize(appID, withLaunchOptions: launchOptions)
        #else
        _ = appID
        #endif
    }

    func refreshAuthorization() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    /// Asks for permission, then brings up OneSignal if it is configured.
    @discardableResult
    func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isAuthorized = granted
        isEnabled = granted
        if granted, let appID = configuration.oneSignalAppID {
            #if canImport(OneSignalFramework)
            OneSignal.initialize(appID, withLaunchOptions: nil)
            OneSignal.Notifications.requestPermission({ _ in }, fallbackToSettings: false)
            #else
            _ = appID
            #endif
        }
        return granted
    }

    func disable() {
        isEnabled = false
        #if canImport(OneSignalFramework)
        OneSignal.User.pushSubscription.optOut()
        #endif
    }

    /// Associates a stable tag with the device so a campaign can target, say, users who
    /// never subscribed. No personal data, no video, no location — ever.
    func setAudienceTag(_ key: String, _ value: String) {
        guard isPushConfigured, isEnabled else { return }
        #if canImport(OneSignalFramework)
        OneSignal.User.addTag(key: key, value: value)
        #endif
    }

    // MARK: - Update available

    /// Checks the App Store for a newer version and, if the user allowed notifications,
    /// posts a local one. Runs at most once a day.
    func checkForUpdate(force: Bool = false) async {
        guard let url = configuration.versionLookupURL else { return }
        if !force, let last = defaults.object(forKey: Key.lastUpdateCheck) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        defaults.set(Date(), forKey: Key.lastUpdateCheck)

        var request = URLRequest(url: url)
        // A cron-adjacent network call with no timeout is how an app hangs forever on a
        // flaky connection. Bound it.
        request.timeoutInterval = 10

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = payload["results"] as? [[String: Any]],
              let storeVersion = results.first?["version"] as? String
        else { return }

        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard Self.isNewer(storeVersion, than: current) else {
            availableUpdateVersion = nil
            return
        }
        availableUpdateVersion = storeVersion

        guard isAuthorized, defaults.string(forKey: Key.notifiedVersion) != storeVersion else { return }
        defaults.set(storeVersion, forKey: Key.notifiedVersion)

        let content = UNMutableNotificationContent()
        content.title = L10n.t("notification.update.title")
        content.body = L10n.t("notification.update.body", storeVersion)
        content.sound = .default
        // Deep link target, so tapping the notification can route straight to the store.
        content.userInfo = ["route": "appstore", "version": storeVersion]

        let request2 = UNNotificationRequest(
            identifier: "update-\(storeVersion)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request2)
    }

    /// Semantic-ish comparison that treats "1.10" as newer than "1.9".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
