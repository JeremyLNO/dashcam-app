import SwiftUI

/// Everything configurable, on the phone — never in the car.
///
/// The screen is built as a stack of coloured blocks rather than one long grey list: a
/// driver looking for the storage cap should find it by the colour of the block, before
/// reading a single heading.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @EnvironmentObject private var language: LanguageManager
    @EnvironmentObject private var storage: StorageManager
    @EnvironmentObject private var notifications: NotificationManager
    @EnvironmentObject private var capture: CaptureManager
    @EnvironmentObject private var autoExporter: AutoExporter
    @Environment(\.openURL) private var openURL

    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(titleKey: "tab.settings", subtitleKey: "settings.subtitle")
                        .padding(.bottom, 2)

                    subscriptionSection
                    recordingSection
                    safetySection
                    storageSection
                    privacySection
                    appSection
                    supportSection
                    brandFooter
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPaywall) {
                PaywallView(context: .general)
                    .environmentObject(environment)
                    .environmentObject(subscriptions)
            }
        }
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        SettingsSection(
            titleKey: "settings.section.subscription",
            subtitleKey: "settings.subscription.subtitle",
            systemImage: "crown.fill",
            accent: .violet
        ) {
            SettingsRow(titleKey: "settings.subscription.status") {
                Text(key: subscriptionStatusKey)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(subscriptions.state.canExport ? Theme.success : Theme.textSecondary)
            }

            if subscriptions.state.isInIntroductoryOffer {
                SettingsNote(textKey: "settings.subscription.trial_footer")
            }

            if !subscriptions.state.canExport {
                Divider().background(Theme.separator)
                Button { showPaywall = true } label: {
                    Text(key: subscriptions.state.hasActiveEntitlement ? "settings.subscription.upgrade" : "settings.subscription.subscribe")
                }
                .buttonStyle(SoftButtonStyle(fill: Theme.violet, foreground: .white, height: 52))
                .accessibilityIdentifier("openPaywall")
                .padding(.top, 4)
            }

            Divider().background(Theme.separator)

            ToggleRow(
                titleKey: "settings.auto_export",
                systemImage: "square.and.arrow.up.fill",
                accent: .blue,
                isOn: binding(\.autoExportProtected)
            )
            .accessibilityIdentifier("autoExportToggle")
            SettingsNote(textKey: "settings.auto_export.footer")
            if let outcome = autoExportNoteKey {
                SettingsNote(textKey: outcome)
            }

            Button {
                Task { await subscriptions.restore() }
            } label: {
                Text(key: "paywall.restore")
            }
            .buttonStyle(SoftButtonStyle(fill: Theme.violetSoft, foreground: Theme.violet, height: 48, font: .system(size: 16, weight: .bold)))
        }
    }

    /// What the last automatic export did, when it did something worth saying. Silence
    /// otherwise: a line reporting success after every drive would become wallpaper.
    private var autoExportNoteKey: String? {
        guard settingsStore.settings.autoExportProtected else { return nil }
        switch autoExporter.lastOutcome {
        case .skippedNoSubscription: return "settings.auto_export.needs_subscription"
        case .skippedNoPermission: return "settings.auto_export.needs_photos"
        case .failed: return "settings.auto_export.failed"
        case .exported, .none: return nil
        }
    }

    /// The lock is only offered when the device actually has biometry enrolled —
    /// otherwise the toggle would promise something that immediately fails.
    private var biometricsAvailable: Bool { BiometricGate().isAvailable }

    private var subscriptionStatusKey: String {
        if !subscriptions.state.isDetermined { return "settings.subscription.checking" }
        if subscriptions.state.isInIntroductoryOffer { return "settings.subscription.trial" }
        if subscriptions.state.hasActiveEntitlement { return "settings.subscription.active" }
        return "settings.subscription.none"
    }

    // MARK: - Recording

    private var recordingSection: some View {
        SettingsSection(
            titleKey: "settings.section.recording",
            subtitleKey: "settings.recording.subtitle",
            systemImage: "video.fill",
            accent: .coral
        ) {
            // A navigation link rather than a menu: each quality tier has to state its
            // cost in GB per hour, and a menu collapses every option to its title.
            OptionPickerRow(
                titleKey: "settings.quality",
                systemImage: "sparkles",
                accent: .violet,
                options: VideoQuality.allCases,
                detail: { Format.gigabytesPerHour($0.gigabytesPerHour) },
                selection: qualityBinding
            )
            OptionPickerRow(
                titleKey: "settings.segment",
                systemImage: "scissors",
                accent: .orange,
                options: SegmentDuration.allCases,
                selection: binding(\.segmentDuration)
            )
            OptionPickerRow(
                titleKey: "settings.lens",
                systemImage: "camera.aperture",
                accent: .coral,
                options: RearLens.allCases,
                detail: { L10n.t($0.detailKey) },
                selection: lensBinding
            )
            ToggleRow(
                titleKey: "settings.adaptive_image",
                systemImage: "sun.max.fill",
                accent: .orange,
                isOn: binding(\.adaptiveImage)
            )
            .accessibilityIdentifier("adaptiveImageToggle")
            ToggleRow(
                titleKey: "settings.front_camera",
                systemImage: "person.fill",
                accent: .blue,
                isOn: frontCameraBinding
            )
            .disabled(!capture.status.isDual && !settingsStore.settings.frontCameraEnabled)
            ToggleRow(
                titleKey: "settings.audio",
                systemImage: "mic.fill",
                accent: .teal,
                isOn: audioBinding
            )
            ToggleRow(
                titleKey: "settings.autostart",
                systemImage: "bolt.fill",
                accent: .orange,
                isOn: binding(\.autoStartOnLaunch)
            )
            ToggleRow(
                titleKey: "settings.carplay_autostart",
                systemImage: "car.fill",
                accent: .coral,
                isOn: binding(\.startOnCarPlayConnect)
            )
            .accessibilityIdentifier("carPlayAutoStart")

            NavigationLink {
                MountAssistant()
                    .environmentObject(capture)
            } label: {
                SettingsRow(titleKey: "mount.title", systemImage: "car.side.and.exclamationmark", accent: .coral) {
                    chevron
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mountAssistant")

            SettingsNote(textKey: "settings.adaptive_image.footer")
            SettingsNote(textKey: capture.status.isDual ? "settings.recording.footer" : "settings.recording.footer.single")
            SettingsNote(textKey: "settings.carplay_autostart.footer")
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        SettingsSection(
            titleKey: "settings.section.safety",
            subtitleKey: "settings.safety.subtitle",
            systemImage: "shield.fill",
            accent: .blue
        ) {
            ToggleRow(
                titleKey: "settings.impact",
                systemImage: "car.side.rear.and.collision.and.car.side.front",
                accent: .coral,
                isOn: binding(\.impactDetectionEnabled)
            )
            if settingsStore.settings.impactDetectionEnabled {
                OptionPickerRow(
                    titleKey: "settings.sensitivity",
                    systemImage: "dial.high.fill",
                    accent: .orange,
                    options: ShockSensitivity.allCases,
                    selection: binding(\.shockSensitivity)
                )
                ToggleRow(
                    titleKey: "settings.braking",
                    systemImage: "exclamationmark.circle.fill",
                    accent: .blue,
                    isOn: binding(\.harshBrakingDetectionEnabled)
                )
            }
            OptionPickerRow(
                titleKey: "settings.discreet",
                systemImage: "moon.fill",
                accent: .violet,
                options: DiscreetDelay.allCases,
                selection: binding(\.discreetDelay)
            )

            SettingsNote(textKey: "settings.safety.footer")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        SettingsSection(
            titleKey: "settings.section.storage",
            subtitleKey: "settings.storage.subtitle",
            systemImage: "internaldrive.fill",
            accent: .teal
        ) {
            storageBar

            OptionPickerRow(
                titleKey: "settings.retention",
                systemImage: "calendar",
                accent: .orange,
                options: RetentionPolicy.allCases,
                selection: binding(\.retention)
            )
            OptionPickerRow(
                titleKey: "settings.storage_limit",
                systemImage: "gauge.with.dots.needle.33percent",
                accent: .teal,
                options: StorageLimit.allCases,
                selection: binding(\.storageLimit)
            )
            SettingsRow(titleKey: "settings.storage_protected_included", systemImage: "checkmark.shield.fill", accent: .green) {
                Text(verbatim: Format.bytes(storage.snapshot.protectedBytes))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }

            SettingsNote(textKey: "settings.storage.footer")
        }
    }

    /// What Dashcam Pocket occupies, next to what the rest of the phone occupies.
    ///
    /// The previous version put "Used by Dashcam" above a bar that measured the whole
    /// device: the app looked like it was eating hundreds of gigabytes. The figure the
    /// app is responsible for is now the large one, in its own colour, and the phone's
    /// total is what it is measured against — never confused with it.
    private var storageBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(key: "settings.storage_app")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(verbatim: Format.bytes(storage.snapshot.dashcamBytes))
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.teal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // Three slices of one disk: this app, everything else, and what is left.
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(storage.snapshot.isCriticallyLow ? Theme.danger : Theme.teal)
                        .frame(width: max(4, proxy.size.width * dashcamFraction))
                    Capsule()
                        .fill(Theme.textSecondary.opacity(0.35))
                        .frame(width: max(2, proxy.size.width * otherFraction))
                    Capsule()
                        .fill(Theme.surfaceElevated)
                }
            }
            .frame(height: 12)

            HStack(spacing: 14) {
                legend(key: "settings.storage_app_short", value: Format.bytes(storage.snapshot.dashcamBytes), colour: Theme.teal)
                legend(key: "settings.storage_other", value: Format.bytes(otherUsedBytes), colour: Theme.textSecondary.opacity(0.35))
                legend(key: "settings.storage_free", value: Format.bytes(storage.snapshot.freeBytes), colour: Theme.surfaceElevated)
            }

            Text(verbatim: L10n.t("settings.storage_share", Format.bytes(storage.snapshot.totalBytes)))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: L10n.t("settings.storage_app") + ": " + Format.bytes(storage.snapshot.dashcamBytes)))
    }

    private func legend(key: String, value: String, colour: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(key: key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: value)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Everything on the phone that is not this app's recordings.
    private var otherUsedBytes: Int64 {
        max(0, storage.snapshot.totalBytes - storage.snapshot.freeBytes - storage.snapshot.dashcamBytes)
    }

    private var dashcamFraction: Double {
        fraction(of: storage.snapshot.dashcamBytes)
    }

    private var otherFraction: Double {
        fraction(of: otherUsedBytes)
    }

    private func fraction(of bytes: Int64) -> Double {
        let total = Double(storage.snapshot.totalBytes)
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / total))
    }

    // MARK: - Privacy & metadata

    private var privacySection: some View {
        SettingsSection(
            titleKey: "settings.section.metadata",
            subtitleKey: "settings.privacy.subtitle",
            systemImage: "lock.fill",
            accent: .orange
        ) {
            ToggleRow(
                titleKey: "settings.location",
                systemImage: "location.fill",
                accent: .teal,
                isOn: locationBinding
            )
            // Offered only while it can do something: iOS raises the Always prompt for an
            // app that already holds When In Use, once. Asking anywhere else raises nothing
            // at all, which is the kind of silence a driver reads as a refusal.
            if LocationUpgrade.isOfferable(
                authorization: environment.location.authorization,
                wantsLocation: settingsStore.settings.locationMetadataEnabled
            ) {
                Button {
                    environment.requestAlwaysLocation()
                } label: {
                    SettingsRow(
                        titleKey: "settings.location.always",
                        systemImage: "location.circle.fill",
                        accent: .teal
                    ) {
                        chevron
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("alwaysLocationRow")
                SettingsNote(textKey: "settings.location.always.footer")
            }
            if biometricsAvailable {
                ToggleRow(
                    titleKey: "settings.biometric",
                    systemImage: "faceid",
                    accent: .orange,
                    isOn: binding(\.requireBiometricUnlock)
                )
                .accessibilityIdentifier("biometricToggle")
            }
            ToggleRow(
                titleKey: "settings.certify",
                systemImage: "checkmark.seal.fill",
                accent: .violet,
                isOn: binding(\.certifyExports)
            )
            .accessibilityIdentifier("certifyToggle")
            SettingsNote(textKey: "settings.certify.footer")

            ToggleRow(
                titleKey: "settings.overlay",
                systemImage: "text.below.photo.fill",
                accent: .violet,
                isOn: binding(\.overlayEnabled)
            )
            if settingsStore.settings.overlayEnabled {
                overlayToggle(.date, key: "settings.overlay.date")
                overlayToggle(.time, key: "settings.overlay.time")
                overlayToggle(.location, key: "settings.overlay.location")
                overlayToggle(.speed, key: "settings.overlay.speed")
            }

            SettingsNote(textKey: "settings.metadata.footer")
        }
    }

    private func overlayToggle(_ field: OverlayFields, key: String) -> some View {
        ToggleRow(
            titleKey: key,
            systemImage: "checkmark",
            accent: .violet,
            isIndented: true,
            isOn: Binding(
                get: { settingsStore.settings.overlayFields.contains(field) },
                set: { isOn in
                    var fields = settingsStore.settings.overlayFields
                    if isOn { fields.insert(field) } else { fields.remove(field) }
                    settingsStore.settings.overlayFields = fields
                }
            )
        )
    }

    // MARK: - Language & notifications

    private var appSection: some View {
        SettingsSection(
            titleKey: "settings.section.language",
            subtitleKey: "settings.app.subtitle",
            systemImage: "globe",
            accent: .blue
        ) {
            SettingsRow(titleKey: "settings.language", systemImage: "character.bubble.fill", accent: .blue) {
                Picker(selection: Binding(
                    get: { language.language },
                    set: { language.select($0) }
                )) {
                    Text(key: "language.system").tag(AppLanguage.system)
                    ForEach(AppLanguage.concrete) { option in
                        Text(verbatim: option.nativeName).tag(option)
                    }
                } label: {
                    Text(key: "settings.language")
                }
                .pickerStyle(.menu)
                .tint(Theme.blue)
                .accessibilityIdentifier("languagePicker")
            }

            ToggleRow(
                titleKey: "settings.notifications",
                systemImage: "bell.fill",
                accent: .orange,
                isOn: Binding(
                    get: { notifications.isEnabled },
                    set: { isOn in
                        Task {
                            if isOn { await notifications.enable() }
                            else { notifications.disable() }
                        }
                    }
                )
            )
            .disabled(!notifications.isPushConfigured)

            if let version = notifications.availableUpdateVersion {
                Button {
                    if let id = environment.configuration.appStoreAppID,
                       let url = URL(string: "https://apps.apple.com/app/id\(id)") {
                        openURL(url)
                    }
                } label: {
                    SettingsRow(titleKey: "settings.update_available", systemImage: "arrow.down.circle.fill", accent: .green) {
                        Text(verbatim: version)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.success)
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsNote(textKey: "settings.language.footer")
        }
    }

    // MARK: - Support & brand

    private var supportSection: some View {
        SettingsSection(
            titleKey: "settings.section.support",
            subtitleKey: "settings.support.subtitle",
            systemImage: "lifepreserver.fill",
            accent: .violet
        ) {
            Button {
                if let url = environment.configuration.supportURL { openURL(url) }
            } label: {
                SettingsRow(titleKey: "settings.support", systemImage: "lightbulb.max.fill", accent: .orange) {
                    chevron
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("supportLink")

            Button {
                if let url = environment.configuration.privacyURL { openURL(url) }
            } label: {
                SettingsRow(titleKey: "paywall.privacy", systemImage: "hand.raised.fill", accent: .blue) {
                    chevron
                }
            }
            .buttonStyle(.plain)

            Button {
                if let url = environment.configuration.termsURL { openURL(url) }
            } label: {
                SettingsRow(titleKey: "paywall.terms", systemImage: "doc.text.fill", accent: .teal) {
                    chevron
                }
            }
            .buttonStyle(.plain)

            Button {
                // Nothing is undone: the pages explain and switch things on, they do not
                // reset anything. Someone who skipped them once can walk through them
                // without losing the settings they have since chosen.
                settingsStore.hasCompletedOnboarding = false
            } label: {
                SettingsRow(titleKey: "settings.replay_onboarding", systemImage: "sparkles.rectangle.stack", accent: .coral) {
                    chevron
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("replayOnboarding")

            SettingsRow(titleKey: "settings.version", systemImage: "number", accent: .violet) {
                Text(verbatim: appVersion)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
    }

    private var brandFooter: some View {
        Button {
            if let url = environment.configuration.brandURL { openURL(url) }
        } label: {
            VStack(spacing: 8) {
                Image("CrazyBeeLabsLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 46)
                Text(verbatim: "crazybeelabs.com")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("brandLink")
        .accessibilityLabel(Text(key: "a11y.brand_link"))
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<RecordingSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }

    /// Quality and the cabin-camera switch both re-shape the capture graph, which a live
    /// multi-cam session cannot do in place — so they rebuild it.
    private var qualityBinding: Binding<VideoQuality> {
        Binding(
            get: { settingsStore.settings.quality },
            set: { newValue in
                settingsStore.settings.quality = newValue
                Task { await environment.reconfigureCapture() }
            }
        )
    }

    /// Changing lens means a different capture device, so the graph is rebuilt — the
    /// same reason quality and the cabin camera do.
    private var lensBinding: Binding<RearLens> {
        Binding(
            get: { settingsStore.settings.rearLens },
            set: { newValue in
                settingsStore.settings.rearLens = newValue
                Task { await environment.reconfigureCapture() }
            }
        )
    }

    private var frontCameraBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.frontCameraEnabled },
            set: { newValue in
                settingsStore.settings.frontCameraEnabled = newValue
                Task { await environment.reconfigureCapture() }
            }
        )
    }

    /// Turning audio on needs the microphone permission first; the toggle springs back
    /// if the user refuses, rather than silently recording nothing.
    private var audioBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.recordAudio },
            set: { newValue in
                guard newValue else {
                    settingsStore.settings.recordAudio = false
                    return
                }
                Task {
                    let status = await environment.permissions.request(.microphone)
                    settingsStore.settings.recordAudio = status == .granted
                }
            }
        )
    }

    private var locationBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.locationMetadataEnabled },
            set: { newValue in
                settingsStore.settings.locationMetadataEnabled = newValue
                if newValue { environment.location.requestAuthorization() }
            }
        )
    }
}

// MARK: - Section furniture

/// A category: a coloured ground, a titled header, and a white card holding the rows.
struct SettingsSection<Content: View>: View {
    let titleKey: String
    var subtitleKey: String?
    let systemImage: String
    let accent: Accent
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(systemImage: systemImage, accent: accent, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(key: titleKey)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitleKey {
                        Text(key: subtitleKey)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(accent.soft)
        )
    }
}

/// One line inside a section: an optional icon, a title, and whatever the setting shows
/// on its right.
struct SettingsRow<Trailing: View>: View {
    let titleKey: String
    var systemImage: String?
    var accent: Accent = .blue
    var isIndented: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                IconBadge(systemImage: systemImage, accent: accent, isFilled: false, size: isIndented ? 28 : 34)
            }
            Text(key: titleKey)
                .font(.system(size: isIndented ? 15 : 16, weight: isIndented ? .regular : .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, isIndented ? 14 : 0)
        .frame(minHeight: 40)
        // The row is a title, a `Spacer` and a value, and a `Spacer` takes no touches:
        // without this, a tap that lands between the two texts hits nothing at all. It
        // is invisible on a narrow iPhone, where the value reaches the middle of the row
        // anyway, and plainly broken on a 6.9" one, where it does not — the middle of
        // every picker row there was simply dead.
        .contentShape(Rectangle())
    }
}

/// A switch. Green when on, because green is the app's word for "granted".
struct ToggleRow: View {
    let titleKey: String
    let systemImage: String
    var accent: Accent = .blue
    var isIndented: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(titleKey: titleKey, systemImage: systemImage, accent: accent, isIndented: isIndented) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.success)
        }
    }
}

/// A choice that opens its own screen. The options are listed with their consequences —
/// a quality tier is meaningless without the gigabytes per hour beside it.
struct OptionPickerRow<Option: SettingsOption>: View {
    let titleKey: String
    let systemImage: String
    var accent: Accent = .blue
    let options: [Option]
    var detail: ((Option) -> String)?
    @Binding var selection: Option

    var body: some View {
        NavigationLink {
            OptionPickerScreen(titleKey: titleKey, options: options, detail: detail, selection: $selection)
        } label: {
            SettingsRow(titleKey: titleKey, systemImage: systemImage, accent: accent) {
                HStack(spacing: 6) {
                    Text(key: selection.titleKey)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(accent.strong)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        // Combined and named after the setting: left to itself the row answers to
        // "Quality, Standard — 1080p", which is nobody's idea of what the control is
        // called — neither VoiceOver's nor a test's.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(key: titleKey))
        .accessibilityValue(Text(key: selection.titleKey))
    }
}

/// The list of options behind an `OptionPickerRow`.
struct OptionPickerScreen<Option: SettingsOption>: View {
    let titleKey: String
    let options: [Option]
    var detail: ((Option) -> String)?
    @Binding var selection: Option
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(key: option.titleKey)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                if let detail {
                                    Text(verbatim: detail(option))
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if option.id == selection.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Theme.success)
                            }
                        }
                        .dashcamCard(padding: 16, corner: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Theme.background)
        .navigationTitle(Text(key: titleKey))
        .navigationBarTitleDisplayMode(.inline)
        // Named, because the screen's own title is translated and the option titles are
        // also written on the row that opens this screen: an identifier is the only way a
        // test can tell "the picker is open" from "the tap did nothing".
        .accessibilityIdentifier("optionPicker")
    }
}

/// A quiet explanatory line under a group of settings.
struct SettingsNote: View {
    let textKey: String

    var body: some View {
        Text(key: textKey)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What an option needs to be listed: an identity and a name.
protocol SettingsOption: Identifiable, Hashable {
    var titleKey: String { get }
}

extension VideoQuality: SettingsOption {}
extension RearLens: SettingsOption {}
extension SegmentDuration: SettingsOption {}
extension RetentionPolicy: SettingsOption {}
extension StorageLimit: SettingsOption {}
extension ShockSensitivity: SettingsOption {}
extension DiscreetDelay: SettingsOption {}
