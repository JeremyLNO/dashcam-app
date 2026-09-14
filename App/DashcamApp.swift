import SwiftUI
import UIKit

@main
struct DashcamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The bar appearance has to be set before the first bar exists: `UIBar*.appearance()`
    /// is a proxy consulted at creation time, so doing this from a view's `onAppear` —
    /// as it was — left the tab bar wearing the system's default grey for the life of the
    /// process.
    init() {
        RootView.applyBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            if let environment = appDelegate.environment {
                RootView()
                    .environmentObject(environment)
                    .environmentObject(environment.settingsStore)
                    .environmentObject(environment.language)
                    .environmentObject(environment.recording)
                    .environmentObject(environment.capture)
                    .environmentObject(environment.subscriptions)
                    .environmentObject(environment.storage)
                    .environmentObject(environment.exporter)
                    .environmentObject(environment.autoExporter)
                    .environmentObject(environment.notifications)
                    .environmentObject(environment.review)
                    .environmentObject(environment.location)
                    .environmentObject(environment.thermal)
                    .environmentObject(environment.protection)
                    .environmentObject(environment.permissions)
                    .modelContainer(environment.container)
                    // Left over from the dark interface this app used to have. It is
                    // overruled twice below — by `RootView`'s own modifier and by the
                    // window's `overrideUserInterfaceStyle` — so it changes nothing on
                    // screen, and a contradiction sitting in the entry point is a trap
                    // for whoever reads it next.
                    .preferredColorScheme(.light)
            }
        }
    }
}

/// Owns the object graph so it exists before any scene — including a CarPlay scene that
/// can connect before the phone window is ever built.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private(set) var environment: AppEnvironment?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LaunchArguments.applyIfNeeded()

        let environment = AppEnvironment()
        self.environment = environment
        AppEnvironment.shared = environment

        Task { @MainActor in
            await environment.bootstrap()
            if LaunchArguments.shouldSeedDemoData {
                await DemoDataSeeder(index: environment.index).seed()
                environment.storage.refresh()
            }
            if LaunchArguments.shouldSeedScreenshots {
                await ScreenshotSeeder(index: environment.index).seed()
                environment.storage.refresh()
            }
        }
        return true
    }
}

/// Test hooks. Only ever active when the harness passes the flag, so a shipping build
/// behaves as if this did not exist.
enum LaunchArguments {
    static var shouldSeedDemoData: Bool { CommandLine.arguments.contains("-uiTestSeed") }
    /// Richer, internally consistent data for App Store screenshots. Separate from the
    /// UI-test seed, which stays minimal so the tests stay fast and deterministic.
    static var shouldSeedScreenshots: Bool { CommandLine.arguments.contains("-screenshotSeed") }
    static var shouldResetState: Bool { CommandLine.arguments.contains("-uiTestReset") }
    static var shouldSkipOnboarding: Bool { CommandLine.arguments.contains("-uiTestSkipOnboarding") }

    static func applyIfNeeded() {
        guard shouldResetState || shouldSeedScreenshots else { return }
        let defaults = UserDefaults.standard
        // `install.` belongs in this list, and its absence cost a whole suite: the
        // satisfaction prompt fires 24 hours after the install date, that date survived
        // the reset, and once the simulator was a day old every UI test met a sheet
        // covering the tab bar. The tests had been passing on the clock, not on merit.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("settings.")
            || key.hasPrefix("onboarding.") || key.hasPrefix("review.")
            || key.hasPrefix("notifications.") || key.hasPrefix("install.") {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: StorageLocations.recordingsRoot)
        // The metadata store has to go with the footage, otherwise the next launch opens
        // a library full of drives whose files were just deleted.
        StorageLocations.removeStoreFiles()
        if shouldSkipOnboarding {
            defaults.set(true, forKey: "onboarding.completed")
        }
    }
}
