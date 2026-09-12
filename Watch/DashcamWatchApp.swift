import SwiftUI

/// The wrist remote.
///
/// One thing makes this worth a target of its own: **Protect**. Everything else in the
/// app can wait for a red light, but keeping the footage of what just happened is the one
/// action a driver wants in the second it happens — and reaching for a cradled phone at
/// that second is exactly what they should not do.
///
/// It is honest about what it cannot do. iOS suspends camera capture the moment the app
/// leaves the foreground, so the watch cannot start a recording on a phone whose app is
/// closed. When that is the case it says so, instead of showing a button that quietly
/// fails.
@main
struct DashcamWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environmentObject(link)
        }
    }
}
