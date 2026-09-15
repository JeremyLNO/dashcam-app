import SwiftUI
import UIKit

/// Tab shell, onboarding gate, and the two things that can interrupt: the satisfaction
/// prompt and the paywall.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var language: LanguageManager
    @EnvironmentObject private var recording: RecordingManager
    @EnvironmentObject private var review: ReviewPrompter

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// Record sits in the middle, and the app opens on it: it is the only screen anyone
    /// needs before setting off.
    /// The tab that shows the cameras. Named rather than written as `1` in three places:
    /// the number is the only thing tying the capture pipeline to the tab bar.
    private static let recordingTab = 1

    @State private var selectedTab = recordingTab

    var body: some View {
        Group {
            if settingsStore.hasCompletedOnboarding {
                tabs
            } else {
                OnboardingView()
            }
        }
        // Rebuilding the tree on a language change is what makes the switch immediate:
        // the strings are read at render time from the selected bundle.
        .id(language.effectiveLanguage.rawValue)
        .tint(Theme.coral)
        // The palette is a light one, top to bottom. Following the system into dark mode
        // would leave half the app cream and the other half charcoal, and every pastel
        // ground unreadable — so the appearance is fixed rather than inherited.
        .preferredColorScheme(.light)
        // Windows are created after the app's initialiser runs, so the style is forced
        // again once there is something to force it on.
        .onAppear { Self.forceLightWindows() }
        .onChange(of: scenePhase) { _, phase in
            handle(phase: phase)
        }
        // …and a drive beginning from anywhere brings them back, whatever is on screen.
        .onChange(of: recording.isRecording) { _, _ in applyCapturePresence() }
        // Leaving the recording tab gives the video pipeline back. Cf. `CapturePresence`.
        .onChange(of: selectedTab) { _, _ in applyCapturePresence() }
        .sheet(isPresented: $review.isPrompting) {
            SatisfactionPrompt(
                onHappy: { review.answerHappy { openURL($0) } },
                onUnhappy: { review.answerUnhappy { openURL($0) } },
                onDismiss: { review.dismiss() }
            )
            .presentationDetents([.height(300)])
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem {
                    Label(title: { Text(key: "tab.videos") }, icon: { Image(systemName: "folder.fill") })
                }
                .tag(0)

            RecordingView()
                .tabItem {
                    Label(title: { Text(key: "tab.record") }, icon: { Image(systemName: "record.circle") })
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label(title: { Text(key: "tab.settings") }, icon: { Image(systemName: "gearshape.fill") })
                }
                .tag(2)
        }
    }

    private func handle(phase: ScenePhase) {
        switch phase {
        case .active:
            environment.permissions.refresh()
            environment.storage.refresh()
            environment.notifications.refreshAuthorization()
            review.evaluate(isRecording: recording.isRecording)
            applyCapturePresence()
            environment.applyLocationIntent(isForeground: true)
        case .inactive:
            break
        case .background:
            // iOS suspends capture in the background whatever the app claims, so the
            // honest thing is to close the recording cleanly rather than leave a
            // half-written segment behind.
            if recording.isRecording {
                Task { await recording.stop() }
            }
            environment.capture.stopRunning()
            environment.applyLocationIntent(isForeground: false)
            environment.index.save()
        @unknown default:
            break
        }
    }

    /// The cameras follow what is on screen, not what the app is.
    private func applyCapturePresence() {
        let shouldRun = CapturePresence.shouldRun(
            isRecording: recording.isRecording,
            isShowingCameras: selectedTab == Self.recordingTab,
            isForeground: scenePhase == .active
        )
        if shouldRun {
            environment.capture.startRunning()
        } else {
            environment.capture.stopRunning()
        }
    }
}

extension RootView {
    /// UIKit still owns the tab bar and the navigation bar. Both are repainted in the
    /// app's cream rather than the system's translucent grey, which reads as a different
    /// application sitting under the content.
    /// `preferredColorScheme` governs SwiftUI's own drawing; it does not reach the UIKit
    /// views underneath — the tab bar, the navigation bar, and MapKit, which renders dark
    /// tiles the moment it believes the interface is dark.
    static func forceLightWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = .light
            }
        }
    }

    static func applyBarAppearance() {
        let ground = UIColor(Theme.background)

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = ground
        tab.shadowColor = UIColor(Theme.separator)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = ground
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

/// "Are you happy with Dashcam?" — one question, two doors.
struct SatisfactionPrompt: View {
    let onHappy: () -> Void
    let onUnhappy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            IconBadge(systemImage: "hand.thumbsup.fill", accent: .coral, size: 62)
            Text(key: "review.title")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: onUnhappy) {
                    Text(key: "review.no")
                }
                .buttonStyle(SoftButtonStyle(fill: Theme.surfaceElevated, foreground: Theme.textPrimary, height: 58))
                .accessibilityIdentifier("reviewNo")

                Button(action: onHappy) {
                    Text(key: "review.yes")
                }
                .buttonStyle(SoftButtonStyle(fill: Theme.coral, foreground: .white, height: 58))
                .accessibilityIdentifier("reviewYes")
            }
            .padding(.horizontal, 20)

            Button(action: onDismiss) {
                Text(key: "review.later")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
