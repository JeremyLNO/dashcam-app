import SwiftUI

/// Everything configurable, on the phone — never in the car.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @EnvironmentObject private var language: LanguageManager
    @EnvironmentObject private var storage: StorageManager
    @EnvironmentObject private var notifications: NotificationManager
    @EnvironmentObject private var capture: CaptureManager
    @Environment(\.openURL) private var openURL

    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                subscriptionSection
                recordingSection
                storageSection
                safetySection
                metadataSection
                appearanceSection
                notificationsSection
                supportSection
                brandFooter
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(Text(key: "tab.settings"))
            .sheet(isPresented: $showPaywall) {
                PaywallView(context: .general)
                    .environmentObject(environment)
                    .environmentObject(subscriptions)
            }
        }
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        Section {
            HStack {
                Text(key: "settings.subscription.status")
                Spacer()
                Text(key: subscriptionStatusKey)
                    .foregroundStyle(subscriptions.state.canExport ? Theme.positive : Theme.textSecondary)
            }
            if !subscriptions.state.canExport {
                Button { showPaywall = true } label: {
                    Text(key: subscriptions.state.hasActiveEntitlement ? "settings.subscription.upgrade" : "settings.subscription.subscribe")
                }
                .accessibilityIdentifier("openPaywall")
            }
            Button {
                Task { await subscriptions.restore() }
            } label: {
                Text(key: "paywall.restore")
            }
        } header: {
            Text(key: "settings.section.subscription")
        } footer: {
            if subscriptions.state.isInIntroductoryOffer {
                Text(key: "settings.subscription.trial_footer")
            }
        }
    }

    private var subscriptionStatusKey: String {
        if !subscriptions.state.isDetermined { return "settings.subscription.checking" }
        if subscriptions.state.isInIntroductoryOffer { return "settings.subscription.trial" }
        if subscriptions.state.hasActiveEntitlement { return "settings.subscription.active" }
        return "settings.subscription.none"
    }

    // MARK: - Recording

    private var recordingSection: some View {
        Section {
            Picker(selection: qualityBinding) {
                ForEach(VideoQuality.allCases) { quality in
                    VStack(alignment: .leading) {
                        Text(key: quality.titleKey)
                        Text(verbatim: Format.gigabytesPerHour(quality.gigabytesPerHour))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .tag(quality)
                }
            } label: {
                Text(key: "settings.quality")
            }
            // A menu-style picker collapses each row to its title, which would hide the
            // GB/hour figure that makes the choice meaningful.
            .pickerStyle(.navigationLink)

            Picker(selection: binding(\.segmentDuration)) {
                ForEach(SegmentDuration.allCases) { duration in
                    Text(key: duration.titleKey).tag(duration)
                }
            } label: {
                Text(key: "settings.segment")
            }

            Toggle(isOn: frontCameraBinding) {
                Text(key: "settings.front_camera")
            }
            .disabled(!capture.status.isDual && !settingsStore.settings.frontCameraEnabled)

            Toggle(isOn: audioBinding) {
                Text(key: "settings.audio")
            }

            Toggle(isOn: binding(\.autoStartOnLaunch)) {
                Text(key: "settings.autostart")
            }
        } header: {
            Text(key: "settings.section.recording")
        } footer: {
            Text(key: capture.status.isDual ? "settings.recording.footer" : "settings.recording.footer.single")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            Picker(selection: binding(\.retention)) {
                ForEach(RetentionPolicy.allCases) { policy in
                    Text(key: policy.titleKey).tag(policy)
                }
            } label: {
                Text(key: "settings.retention")
            }

            Picker(selection: binding(\.storageLimit)) {
                ForEach(StorageLimit.allCases) { limit in
                    Text(key: limit.titleKey).tag(limit)
                }
            } label: {
                Text(key: "settings.storage_limit")
            }

            LabeledContent {
                Text(verbatim: Format.bytes(storage.snapshot.dashcamBytes))
            } label: {
                Text(key: "settings.storage_used")
            }

            LabeledContent {
                Text(verbatim: Format.bytes(storage.snapshot.protectedBytes))
            } label: {
                Text(key: "settings.storage_protected")
            }

            LabeledContent {
                Text(verbatim: Format.bytes(storage.snapshot.freeBytes))
            } label: {
                Text(key: "settings.storage_free")
            }
        } header: {
            Text(key: "settings.section.storage")
        } footer: {
            Text(key: "settings.storage.footer")
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section {
            Toggle(isOn: binding(\.impactDetectionEnabled)) {
                Text(key: "settings.impact")
            }
            if settingsStore.settings.impactDetectionEnabled {
                Picker(selection: binding(\.shockSensitivity)) {
                    ForEach(ShockSensitivity.allCases) { sensitivity in
                        Text(key: sensitivity.titleKey).tag(sensitivity)
                    }
                } label: {
                    Text(key: "settings.sensitivity")
                }
            }
            Picker(selection: binding(\.discreetDelay)) {
                ForEach(DiscreetDelay.allCases) { delay in
                    Text(key: delay.titleKey).tag(delay)
                }
            } label: {
                Text(key: "settings.discreet")
            }
        } header: {
            Text(key: "settings.section.safety")
        } footer: {
            Text(key: "settings.safety.footer")
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Section {
            Toggle(isOn: locationBinding) {
                Text(key: "settings.location")
            }
            Toggle(isOn: binding(\.overlayEnabled)) {
                Text(key: "settings.overlay")
            }
            if settingsStore.settings.overlayEnabled {
                overlayToggle(.date, key: "settings.overlay.date")
                overlayToggle(.time, key: "settings.overlay.time")
                overlayToggle(.location, key: "settings.overlay.location")
                overlayToggle(.speed, key: "settings.overlay.speed")
            }
        } header: {
            Text(key: "settings.section.metadata")
        } footer: {
            Text(key: "settings.metadata.footer")
        }
    }

    private func overlayToggle(_ field: OverlayFields, key: String) -> some View {
        Toggle(isOn: Binding(
            get: { settingsStore.settings.overlayFields.contains(field) },
            set: { isOn in
                var fields = settingsStore.settings.overlayFields
                if isOn { fields.insert(field) } else { fields.remove(field) }
                settingsStore.settings.overlayFields = fields
            }
        )) {
            Text(key: key)
        }
        .padding(.leading, 12)
    }

    // MARK: - Appearance / language

    private var appearanceSection: some View {
        Section {
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
            .accessibilityIdentifier("languagePicker")
        } header: {
            Text(key: "settings.section.language")
        } footer: {
            Text(key: "settings.language.footer")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { notifications.isEnabled },
                set: { isOn in
                    Task {
                        if isOn { await notifications.enable() }
                        else { notifications.disable() }
                    }
                }
            )) {
                Text(key: "settings.notifications")
            }
            .disabled(!notifications.isPushConfigured)

            if let version = notifications.availableUpdateVersion {
                Button {
                    if let id = environment.configuration.appStoreAppID,
                       let url = URL(string: "https://apps.apple.com/app/id\(id)") {
                        openURL(url)
                    }
                } label: {
                    LabeledContent {
                        Text(verbatim: version).foregroundStyle(Theme.positive)
                    } label: {
                        Text(key: "settings.update_available")
                    }
                }
            }
        } header: {
            Text(key: "settings.section.notifications")
        } footer: {
            Text(key: notifications.isPushConfigured ? "settings.notifications.footer" : "settings.notifications.unconfigured")
        }
    }

    // MARK: - Support & brand

    private var supportSection: some View {
        Section {
            Button {
                if let url = environment.configuration.supportURL { openURL(url) }
            } label: {
                Label(
                    title: { Text(key: "settings.support") },
                    icon: { Image(systemName: "lightbulb.max") }
                )
            }
            .accessibilityIdentifier("supportLink")

            Button {
                if let url = environment.configuration.privacyURL { openURL(url) }
            } label: {
                Label(title: { Text(key: "paywall.privacy") }, icon: { Image(systemName: "hand.raised") })
            }
            Button {
                if let url = environment.configuration.termsURL { openURL(url) }
            } label: {
                Label(title: { Text(key: "paywall.terms") }, icon: { Image(systemName: "doc.text") })
            }

            LabeledContent {
                Text(verbatim: appVersion)
            } label: {
                Text(key: "settings.version")
            }
        } header: {
            Text(key: "settings.section.support")
        }
    }

    private var brandFooter: some View {
        Section {
            Button {
                if let url = environment.configuration.brandURL { openURL(url) }
            } label: {
                VStack(spacing: 8) {
                    Image("CrazyBeeLabsLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 44)
                    Text(verbatim: "crazybeelabs.com")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.brand)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .accessibilityIdentifier("brandLink")
            .accessibilityLabel(Text(key: "a11y.brand_link"))
        }
        .listRowBackground(Color.clear)
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
