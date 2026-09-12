import SwiftUI

/// Five screens, then the app.
///
/// Four of them explain, one asks. The camera prompt is deliberately last: by the time
/// the system alert appears the user already knows what the camera is for, which is the
/// difference between a grant and a permanent deny.
///
/// One idea per screen, one drawing, one sentence. Anything longer is not read at all in
/// the thirty seconds someone gives a new app.
struct OnboardingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var page = 0
    @State private var isRequesting = false

    private struct Page: Identifiable {
        let id: Int
        let titleKey: String
        let bodyKey: String
        let accent: Accent
    }

    private let pages: [Page] = [
        Page(id: 0, titleKey: "onboarding.1.title", bodyKey: "onboarding.1.body", accent: .coral),
        Page(id: 1, titleKey: "onboarding.2.title", bodyKey: "onboarding.2.body", accent: .teal),
        Page(id: 2, titleKey: "onboarding.3.title", bodyKey: "onboarding.3.body", accent: .blue),
        Page(id: 3, titleKey: "onboarding.4.title", bodyKey: "onboarding.4.body", accent: .coral),
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    ForEach(pages) { item in
                        pageView(item).tag(item.id)
                    }
                    featuresPage.tag(pages.count)
                    permissionPage.tag(pages.count + 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                footer
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text(key: "app.name")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if page < pages.count {
                Button { finish() } label: {
                    Text(key: "onboarding.skip")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityIdentifier("onboardingSkip")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func pageView(_ item: Page) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(key: item.titleKey)
                .font(.system(size: 38, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.7)
            Text(key: item.bodyKey)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // The drawing takes whatever room the title leaves, centred in it, rather
            // than sitting against the text with a hole underneath.
            Spacer(minLength: 0)
            OnboardingIllustration(page: item.id)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    /// Explaining a feature and then leaving it buried in Settings is how features go
    /// unused. Each line here says what it does in one sentence and switches it on where
    /// it is read — the only place the reader is already thinking about it.
    ///
    /// Nothing is turned on behind the driver's back: every switch shows the state it is
    /// actually in, defaults included.
    private var featuresPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(key: "onboarding.6.title")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.7)
                Text(key: "onboarding.6.body")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                featureSwitch(
                    icon: "person.fill", accent: .blue,
                    titleKey: "settings.front_camera", detailKey: "onboarding.feature.cabin",
                    isOn: binding(\.frontCameraEnabled)
                )
                featureSwitch(
                    icon: "mic.fill", accent: .teal,
                    titleKey: "settings.audio", detailKey: "onboarding.feature.audio",
                    isOn: binding(\.recordAudio)
                )
                featureSwitch(
                    icon: "car.side.rear.and.collision.and.car.side.front", accent: .coral,
                    titleKey: "settings.impact", detailKey: "onboarding.feature.impact",
                    isOn: binding(\.impactDetectionEnabled)
                )
                featureSwitch(
                    icon: "location.fill", accent: .teal,
                    titleKey: "settings.location", detailKey: "onboarding.feature.location",
                    isOn: binding(\.locationMetadataEnabled)
                )
                featureSwitch(
                    icon: "sun.max.fill", accent: .orange,
                    titleKey: "settings.adaptive_image", detailKey: "onboarding.feature.adaptive",
                    isOn: binding(\.adaptiveImage)
                )
                featureSwitch(
                    icon: "square.and.arrow.up.fill", accent: .violet,
                    titleKey: "settings.auto_export", detailKey: "onboarding.feature.auto_export",
                    isOn: binding(\.autoExportProtected)
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func featureSwitch(icon: String, accent: Accent, titleKey: String, detailKey: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: icon, accent: accent, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(key: titleKey)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(key: detailKey)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.success)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashcamCard(padding: 14, corner: 18)
        .accessibilityElement(children: .contain)
    }

    private func binding(_ keyPath: WritableKeyPath<RecordingSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }

    /// The last card asks for the camera, and names the three permissions that are *not*
    /// being asked for yet — each is requested at the moment it first becomes useful.
    private var permissionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(key: "onboarding.5.title")
                .font(.system(size: 38, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.7)
            Text(key: "onboarding.5.body")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                permissionLine(icon: "camera.fill", key: "permission.camera.explanation", accent: .coral)
                permissionLine(icon: "mic.fill", key: "permission.microphone.explanation", accent: .teal)
                permissionLine(icon: "location.fill", key: "permission.location.explanation", accent: .blue)
                permissionLine(icon: "waveform.path.ecg", key: "permission.motion.explanation", accent: .violet)
            }
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    private func permissionLine(icon: String, key: String, accent: Accent) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(systemImage: icon, accent: accent, size: 38)
            Text(key: key)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashcamCard(padding: 12, corner: 18)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0...(pages.count + 1), id: \.self) { index in
                Capsule()
                    .fill(index == page ? currentAccent.strong : Theme.separator)
                    .frame(width: index == page ? 22 : 8, height: 8)
                    .animation(.easeOut(duration: 0.2), value: page)
            }
        }
        .padding(.bottom, 18)
    }

    private var currentAccent: Accent {
        if page < pages.count { return pages[page].accent }
        return page == pages.count ? .violet : .coral
    }

    /// The camera page is the last one, and the only one whose button asks the system
    /// for something.
    private var isOnPermissionPage: Bool { page == pages.count + 1 }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await advance() }
            } label: {
                if isRequesting {
                    ProgressView().tint(.white)
                } else {
                    HStack(spacing: 10) {
                        Text(key: isOnPermissionPage ? "onboarding.enable_camera" : "common.continue")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .bold))
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(fill: currentAccent.strong, height: 66))
            .accessibilityIdentifier("onboardingContinue")

            if isOnPermissionPage {
                Button {
                    finish()
                } label: {
                    Text(key: "onboarding.later")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func advance() async {
        guard isOnPermissionPage else {
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

/// The drawings.
///
/// Everything here is made of shapes and system symbols — no image assets, nothing to
/// re-export when a colour changes, and nothing that can ship at the wrong scale.
struct OnboardingIllustration: View {
    let page: Int

    var body: some View {
        ZStack {
            switch page {
            case 0: phoneFilmingTheRoad
            case 1: twoCameras
            case 2: protectedMoment
            default: privateByDesign
            }
        }
        .frame(height: 310)
        .padding(.top, 12)
    }

    // MARK: Page 1 — an iPhone filming the road

    private var phoneFilmingTheRoad: some View {
        ZStack {
            Circle()
                .fill(Theme.orangeSoft)
                .frame(width: 230, height: 230)
                .offset(x: -40, y: -40)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.blue.opacity(0.85), Theme.orange.opacity(0.9)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 250, height: 168)
                .overlay(alignment: .bottom) {
                    // The road: two converging edges and a dashed centre line.
                    ZStack {
                        Trapezoid()
                            .fill(Color(hex: 0x3A3F4B))
                            .frame(width: 250, height: 80)
                        VStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { _ in
                                Capsule().fill(Color.white.opacity(0.8)).frame(width: 8, height: 12)
                            }
                        }
                        .offset(y: 10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(alignment: .topLeading) {
                    tag(key: "rec.on", colour: Theme.coral, filled: true).padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.mintSoft)
                        .frame(width: 74, height: 54)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.teal)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white, lineWidth: 3)
                        )
                        .padding(12)
                }
                .softShadow()

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    chip(systemImage: "video.fill", accent: .coral)
                    chip(systemImage: "person.fill", accent: .blue)
                    chip(systemImage: "location.fill", accent: .teal)
                }
            }
            .frame(height: 290)
        }
    }

    // MARK: Page 2 — two cameras, one drive

    private var twoCameras: some View {
        ZStack {
            Circle().fill(Theme.blueSoft).frame(width: 250, height: 250)

            // Two cones, one forward, one backward, with the car between them.
            Cone()
                .fill(Theme.blue.opacity(0.28))
                .frame(width: 190, height: 110)
                .offset(y: -92)
            Cone()
                .fill(Theme.coral.opacity(0.28))
                .rotationEffect(.degrees(180))
                .frame(width: 150, height: 86)
                .offset(y: 88)

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)
                .frame(width: 86, height: 150)
                .overlay(
                    VStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.blueSoft).frame(width: 58, height: 34)
                        RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated).frame(width: 62, height: 40)
                        RoundedRectangle(cornerRadius: 8).fill(Theme.coralSoft).frame(width: 58, height: 30)
                    }
                )
                .softShadow()

            VStack {
                label(key: "camera.rear", accent: .blue).offset(y: -8)
                Spacer()
                label(key: "camera.front", accent: .coral).offset(y: 8)
            }
            .frame(height: 290)
        }
    }

    // MARK: Page 3 — the moment protects itself

    private var protectedMoment: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Theme.blue.opacity(0.75), Theme.teal.opacity(0.75)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(height: 168)
                    .overlay(alignment: .bottom) {
                        Trapezoid().fill(Color(hex: 0x3A3F4B)).frame(height: 78)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.coral, lineWidth: 4)
                            .frame(width: 118, height: 78)
                            .offset(y: 18)
                    )
                    .overlay(alignment: .bottomLeading) {
                        tag(key: "onboarding.auto_saved", colour: Color(hex: 0x08264A).opacity(0.75), filled: true)
                            .padding(12)
                    }

                IconBadge(systemImage: "exclamationmark", accent: .coral, size: 52)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                    .offset(x: 6, y: -18)
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(index == 1 ? Theme.coralSoft : Theme.surfaceElevated)
                        .frame(height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(index == 1 ? Theme.coral : Color.clear, lineWidth: 3)
                        )
                }
            }
        }
    }

    // MARK: Page 4 — nothing leaves the phone

    private var privateByDesign: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.mintSoft).frame(width: 170, height: 170)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white)
                    .frame(width: 104, height: 176)
                    .overlay(
                        IconBadge(systemImage: "lock.fill", accent: .teal, size: 60)
                    )
                    .softShadow()
            }

            VStack(alignment: .leading, spacing: 10) {
                promise(systemImage: "icloud.slash.fill", key: "onboarding.promise.no_cloud", accent: .coral)
                promise(systemImage: "person.crop.circle.badge.xmark", key: "onboarding.promise.no_account", accent: .blue)
                promise(systemImage: "iphone", key: "onboarding.promise.on_device", accent: .orange)
            }
        }
    }

    // MARK: Pieces

    private func promise(systemImage: String, key: String, accent: Accent) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: systemImage, accent: accent, isFilled: false, size: 36)
            Text(key: key)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(systemImage: String, accent: Accent) -> some View {
        IconBadge(systemImage: systemImage, accent: accent, isFilled: false, size: 46)
            .background(Circle().fill(.white).softShadow())
    }

    private func label(key: String, accent: Accent) -> some View {
        Text(key: key)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(accent.strong)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white).softShadow())
    }

    private func tag(key: String, colour: Color, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.white).frame(width: 7, height: 7)
            Text(key: key)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(colour))
    }
}

/// The road: wide at the bottom, narrow at the horizon.
struct Trapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width * 0.13, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.13, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A camera's field of view.
struct Cone: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
