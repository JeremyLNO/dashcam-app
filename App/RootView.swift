import SwiftUI

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

    @State private var selectedTab = 0

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
        .tint(Theme.accent)
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
            RecordingView()
                .tabItem {
                    Label(title: { Text(key: "tab.record") }, icon: { Image(systemName: "record.circle") })
                }
                .tag(0)

            LibraryView()
                .tabItem {
                    Label(title: { Text(key: "tab.videos") }, icon: { Image(systemName: "film.stack") })
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label(title: { Text(key: "tab.settings") }, icon: { Image(systemName: "gearshape") })
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

/// "Are you happy with Dashcam?" — one question, two doors.
struct SatisfactionPrompt: View {
    let onHappy: () -> Void
    let onUnhappy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.thumbsup")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(key: "review.title")
                .font(Theme.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 12) {
                Button(action: onUnhappy) {
                    Text(key: "review.no")
                }
                .buttonStyle(DriverButtonStyle(fill: Theme.surfaceElevated, isProminent: false))
                .accessibilityIdentifier("reviewNo")

                Button(action: onHappy) {
                    Text(key: "review.yes")
                }
                .buttonStyle(DriverButtonStyle(fill: Theme.accent))
                .accessibilityIdentifier("reviewYes")
            }
            .padding(.horizontal, 20)

            Button(action: onDismiss) {
                Text(key: "review.later")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
