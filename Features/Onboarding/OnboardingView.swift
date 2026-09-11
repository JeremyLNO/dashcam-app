import SwiftUI

/// Five screens, then the app.
///
/// Four of them explain, one asks. The camera prompt is deliberately last: by the time
/// the system alert appears the user already knows what the camera is for, which is the
/// difference between a grant and a permanent deny.
struct OnboardingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var page = 0
    @State private var isRequesting = false

    private struct Page: Identifiable {
        let id: Int
        let icon: String
        let titleKey: String
        let bodyKey: String
    }

    private let pages: [Page] = [
        Page(id: 0, icon: "car.side", titleKey: "onboarding.1.title", bodyKey: "onboarding.1.body"),
        Page(id: 1, icon: "iphone.gen3", titleKey: "onboarding.2.title", bodyKey: "onboarding.2.body"),
        Page(id: 2, icon: "shield.lefthalf.filled", titleKey: "onboarding.3.title", bodyKey: "onboarding.3.body"),
        Page(id: 3, icon: "hand.raised.fill", titleKey: "onboarding.4.title", bodyKey: "onboarding.4.body"),
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages) { item in
                        pageView(icon: item.icon, titleKey: item.titleKey, bodyKey: item.bodyKey)
                            .tag(item.id)
                    }
                    permissionPage.tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                footer
            }
        }
    }

    private func pageView(icon: String, titleKey: String, bodyKey: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 68, weight: .thin))
                .foregroundStyle(Theme.accent)
            Text(key: titleKey)
                .font(Theme.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
            Text(key: bodyKey)
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }

    private var permissionPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 68, weight: .thin))
                .foregroundStyle(Theme.accent)
            Text(key: "onboarding.5.title")
                .font(Theme.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
            Text(key: "onboarding.5.body")
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 32)

            // The optional permissions are named here but not requested: each one is
            // asked for at the moment it first becomes useful, never up front.
            VStack(alignment: .leading, spacing: 10) {
                permissionLine(icon: "mic.fill", key: "permission.microphone.explanation")
                permissionLine(icon: "location.fill", key: "permission.location.explanation")
                permissionLine(icon: "waveform.path.ecg", key: "permission.motion.explanation")
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
    }

    private func permissionLine(icon: String, key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 18)
            Text(key: key)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await advance() }
            } label: {
                if isRequesting {
                    ProgressView().tint(.white)
                } else {
                    Text(key: page == pages.count ? "onboarding.enable_camera" : "common.continue")
                }
            }
            .buttonStyle(DriverButtonStyle(fill: Theme.accent))
            .accessibilityIdentifier("onboardingContinue")

            if page == pages.count {
                Button {
                    finish()
                } label: {
                    Text(key: "onboarding.later")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func advance() async {
        guard page == pages.count else {
            withAnimation { page += 1 }
            return
        }
        isRequesting = true
        await environment.permissions.request(.camera)
        isRequesting = false
        // Whatever the answer, onboarding is over: a refused camera is handled by the
        // recording screen, which explains how to fix it in Settings.
        await environment.capture.configureAndStart(settings: settingsStore.settings)
        finish()
    }

    private func finish() {
        settingsStore.hasCompletedOnboarding = true
    }
}
