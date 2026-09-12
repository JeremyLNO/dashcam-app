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
    @State private var selectedTab = 1

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
        .onAppear { Self.applyBarAppearance() }
        .onChange(of: scenePhase) { _, phase in
            handle(phase: phase)
        }
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
            environment.capture.startRunning()
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
            environment.index.save()
        @unknown default:
            break
        }
    }
}

extension RootView {
    /// UIKit still owns the tab bar and the navigation bar. Both are repainted in the
    /// app's cream rather than the system's translucent grey, which reads as a different
    /// application sitting under the content.
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
