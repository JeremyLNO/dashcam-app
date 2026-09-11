import SwiftUI
import UIKit

@main
struct DashcamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                    .environmentObject(environment.notifications)
                    .environmentObject(environment.review)
                    .environmentObject(environment.location)
                    .environmentObject(environment.thermal)
                    .environmentObject(environment.protection)
                    .environmentObject(environment.permissions)
                    .modelContainer(environment.container)
                    .preferredColorScheme(.dark)
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
        }
        return true
    }
}

/// Test hooks. Only ever active when the harness passes the flag, so a shipping build
/// behaves as if this did not exist.
enum LaunchArguments {
    static var shouldSeedDemoData: Bool { CommandLine.arguments.contains("-uiTestSeed") }
    static var shouldResetState: Bool { CommandLine.arguments.contains("-uiTestReset") }
    static var shouldSkipOnboarding: Bool { CommandLine.arguments.contains("-uiTestSkipOnboarding") }

    static func applyIfNeeded() {
        guard shouldResetState else { return }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("settings.")
            || key.hasPrefix("onboarding.") || key.hasPrefix("review.") || key.hasPrefix("notifications.") {
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
