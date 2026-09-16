import AVFoundation
import SwiftData
import SwiftUI
import UIKit

/// The screen the driver looks at.
///
/// Reading order is the point: the road first, then the three things that must be ready
/// before setting off, then the one button that starts the drive. Everything below that
/// line is a figure you consult when stopped, never at speed.
struct RecordingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var recording: RecordingManager
    @EnvironmentObject private var capture: CaptureManager
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var storage: StorageManager
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var thermal: ThermalManager
    /// Shared, not owned: the CarPlay remote turns the discreet screen on and off too, and
    /// the end of a drive has to end it whatever tab the phone happens to be showing.
    @EnvironmentObject private var dimmer: ScreenDimmer

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Read, never written, from here: the drive stats show what the index already holds,
    /// and a SwiftData query is what keeps them current while a recording runs.
    @Query(sort: \DriveSession.startedAt, order: .reverse) private var sessions: [DriveSession]

    @Environment(\.scenePhase) private var scenePhase

    @State private var lastInteraction = Date()
    @State private var discreetTimer: Timer?
    @State private var protectFlash = false

    private var isDiscreet: Bool { dimmer.isDiscreet }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isDiscreet {
                DiscreetScreen(
                    isRecording: recording.isRecording,
                    elapsed: recording.elapsed,
                    status: capture.status,
                    freeSpace: storage.snapshot.freeBytes,
                    wakesOnImpact: recording.isRecording && settingsStore.settings.impactDetectionEnabled,
                    onProtect: protect,
                    onExit: exitDiscreet
                )
                .transition(.opacity)
            } else {
                content
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isDiscreet)
        .onAppear { scheduleDiscreet() }
        .onDisappear {
            discreetTimer?.invalidate()
            // Leaving this tab with the display at 5 % would hand the rest of the app —
            // and then the rest of the phone — a screen nobody can read.
            exitDiscreet()
        }
        .onChange(of: settingsStore.settings.discreetDelay) { _, _ in scheduleDiscreet() }
        // A collision is not a moment to be looking at a black screen: the app has
        // something to say, and it cannot say it in the dark.
        .onChange(of: recording.lastDetectedEvent) { _, event in
            guard let event, ScreenDimmer.wakes(event.origin) else { return }
            exitDiscreet()
        }
        // A drive is the only reason to be dark, so it is also what arms the countdown —
        // and it arms it **from its own first second**. A delay of five seconds means five
        // seconds of *this* drive, not five seconds after whatever the driver last touched
        // before setting off.
        .onChange(of: recording.isRecording) { _, isRecording in
            if isRecording { scheduleDiscreet() } else { exitDiscreet() }
        }
        // The brightness belongs to the whole phone, not to this app: whatever takes the
        // foreground next gets it back, and dimming resumes when this screen returns.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if isDiscreet { dimmer.dim() }
            } else {
                dimmer.restore()
            }
        }
        .alert(item: $recording.alert) { alert in
            Alert(
                title: Text(key: alert.titleKey),
                message: Text(key: alert.messageKey),
                dismissButton: .default(Text(key: "common.ok"))
            )
        }
    }

    // MARK: - Layout

    /// Landscape is the orientation this app is meant to be used in — a windscreen cradle
    /// holds the phone sideways — so it gets a layout of its own rather than a squashed
    /// version of the portrait one: the road fills the left two thirds, everything the
    /// driver reads sits in a column on the right.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// The shape of the file being written, not a shape of the preview's own choosing.
    /// A 16:9 recording shown in a 4:3 box either crops the road away or pads it with
    /// bars, and in both cases the driver is not looking at what is being recorded.
    private var previewAspect: CGFloat {
        let format = VideoFormatDescriptor.resolved(for: thermal.effectiveQuality, codec: "")
        guard format.outputHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(format.outputWidth) / CGFloat(format.outputHeight)
    }

    private var controlHeight: CGFloat {
        isLandscape ? Theme.compactControlHeight : Theme.controlHeight
    }

    private var content: some View {
        Group {
            if isLandscape {
                landscapeContent
            } else {
                portraitContent
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { noteInteraction() }
    }

    private var portraitContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                previews
                    .aspectRatio(previewAspect, contentMode: .fit)
                hardwareRow
                controls
                // While recording, the figures give way: the road and the two controls
                // are all a driver should have to look at. They are a pre-flight check,
                // not something to read at speed.
                if !recording.isRecording {
                    driveStats
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var landscapeContent: some View {
        HStack(alignment: .top, spacing: 14) {
            previews
                .aspectRatio(previewAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                // The tab bar floats over the content, so the preview has to stop short
                // of it rather than disappear behind it.
                .padding(.bottom, Theme.floatingTabBarClearance)

            VStack(spacing: 10) {
                compactHeader
                if !recording.isRecording {
                    hardwareColumn
                }
                Spacer(minLength: 0)
                controls
            }
            .frame(width: 366)
            .padding(.bottom, Theme.floatingTabBarClearance)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key: "app.name")
                    .font(Theme.pageTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(key: "record.tagline")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if recording.isRecording {
                Text(verbatim: Format.duration(recording.elapsed))
                    .font(Theme.timer(30))
                    .foregroundStyle(Theme.coral)
                    .accessibilityLabel(Text(key: "a11y.duration"))
                    .accessibilityValue(Text(verbatim: Format.duration(recording.elapsed)))
            }
        }
    }

    private var compactHeader: some View {
        HStack {
            RecordingIndicator(isRecording: recording.isRecording)
            Spacer()
            Text(verbatim: Format.duration(recording.elapsed))
                .font(Theme.timer(24))
                .foregroundStyle(recording.isRecording ? Theme.coral : Theme.textTertiary)
                .accessibilityLabel(Text(key: "a11y.duration"))
                .accessibilityValue(Text(verbatim: Format.duration(recording.elapsed)))
        }
    }

    // MARK: - Cameras

    /// The road fills the frame; the cabin sits in the corner where the player puts it
    /// too, so the live view and the recording read the same way.
    private var previews: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Group {
                    if capture.status.mode == .unavailable {
                        CameraUnavailableView(messageKey: capture.status.unavailability?.messageKey ?? "capture.error.no_camera")
                    } else {
                        CameraPreviewView(previewLayer: capture.rearPreviewLayer)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))

                if capture.status.frontActive {
                    CameraPreviewView(previewLayer: capture.frontPreviewLayer)
                        .frame(width: proxy.size.width * 0.30, height: proxy.size.width * 0.30 / previewAspect)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                        )
                        .overlay(alignment: .bottom) {
                            previewCaption(key: "camera.front", dotColour: Theme.success)
                                .padding(6)
                        }
                        .padding(12)
                        .accessibilityLabel(Text(key: "a11y.front_preview"))
                }

                VStack {
                    HStack {
                        statePill
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        previewCaption(key: "camera.rear", dotColour: nil)
                        Spacer()
                        dimButton
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity)
        .softShadow()
    }

    /// Turning the screen down is a driver's gesture, so it sits on the road itself,
    /// opposite the camera label and away from Start and Protect — a thumb reaching for
    /// it cannot land on either by accident.
    ///
    /// Deliberately small and unlabelled. It is the one control on this screen that
    /// changes nothing about the recording, and a full-width button would claim an
    /// importance it does not have.
    ///
    /// Inert while stopped, and **shown** inert rather than hidden — the same treatment
    /// Protect gets, for the same reason: a control that disappears reads as a control
    /// that does not exist, and the driver stops looking for it. There is nothing to be
    /// discreet about before a drive starts.
    private var dimButton: some View {
        Button { enterDiscreet() } label: {
            Image(systemName: "moon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color(hex: 0x08264A).opacity(0.72)))
        }
        .buttonStyle(.plain)
        .disabled(!recording.isRecording)
        .opacity(recording.isRecording ? 1 : 0.55)
        .accessibilityIdentifier("dimScreen")
        .accessibilityLabel(Text(key: "discreet.dim"))
        .accessibilityHint(Text(key: "a11y.dim_hint"))
    }

    /// "Ready" before the drive, "REC" during it. Dark capsule so it survives whatever
    /// the camera is pointed at.
    private var statePill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(recording.isRecording ? Theme.coral : Theme.coral.opacity(0.9))
                .frame(width: 10, height: 10)
            Text(key: recording.isRecording ? "rec.on" : "record.ready")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(hex: 0x08264A).opacity(0.72)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(key: recording.isRecording ? "a11y.recording" : "a11y.idle"))
    }

    private func previewCaption(key: String, dotColour: Color?) -> some View {
        HStack(spacing: 5) {
            if let dotColour {
                Circle().fill(dotColour).frame(width: 7, height: 7)
            }
            Text(key: key)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(hex: 0x08264A).opacity(0.72)))
    }

    // MARK: - Hardware state

    /// Three cards, one per thing that has to work: the road camera, the cabin camera,
    /// the position. Colour tells them apart before the labels are read.
    private var hardwareRow: some View {
        HStack(spacing: 10) {
            hardwareCard(
                titleKey: "status.rear",
                systemImage: "video.fill",
                accent: .coral,
                stateKey: signal(for: capture.status.rearActive).stateKey(isRecording: recording.isRecording),
                isOn: signal(for: capture.status.rearActive).isHealthy
            )
            hardwareCard(
                titleKey: "status.front",
                systemImage: "person.fill",
                accent: .blue,
                stateKey: signal(for: capture.status.frontActive).stateKey(isRecording: recording.isRecording),
                isOn: signal(for: capture.status.frontActive).isHealthy
            )
            // GPS is the one of the three a driver can actually change from here, so it
            // is a button rather than a lamp: tapping asks for the permission when it has
            // never been asked, sends them to Settings when they refused it once, and
            // otherwise turns the metadata on and off.
            Button { toggleLocation() } label: {
                hardwareCard(
                    titleKey: "status.gps",
                    systemImage: "location.fill",
                    accent: .teal,
                    stateKey: gpsStateKey,
                    isOn: isLocationOn
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gpsToggle")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(key: "a11y.gps_hint"))
        }
    }

    private var hardwareColumn: some View {
        hardwareRow
    }

    private func hardwareCard(titleKey: String, systemImage: String, accent: Accent, stateKey: String, isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(systemImage: systemImage, accent: accent, size: isLandscape ? 32 : 40)
            Text(key: titleKey)
                .font(.system(size: isLandscape ? 14 : 16, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            StateDot(textKey: stateKey, color: isOn ? Theme.success : Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(accent, padding: isLandscape ? 10 : 14, corner: Theme.tileCorner)
        .accessibilityElement(children: .combine)
    }

    private var readyStateKey: String {
        recording.isRecording ? "status.recording" : "record.ready"
    }

    /// A camera card reads the frames, not the configuration. Cf. `CameraSignal`.
    private func signal(for isActive: Bool) -> CameraSignal {
        CameraSignal.assess(
            isActive: isActive,
            isRunning: capture.status.isRunning,
            lastFrame: capture.status.lastVideoFrame,
            startedRunningAt: capture.status.startedRunningAt
        )
    }

    /// On means both halves are true: the user wants position, and iOS allows it.
    private var isLocationOn: Bool {
        settingsStore.settings.locationMetadataEnabled && location.isAuthorized
    }

    private var gpsStateKey: String {
        if !location.isAuthorized {
            return location.authorization == .denied || location.authorization == .restricted
                ? "status.denied"
                : "status.off"
        }
        if !settingsStore.settings.locationMetadataEnabled { return "status.off" }
        return location.latest == nil ? "status.searching" : readyStateKey
    }

    private func toggleLocation() {
        noteInteraction()
        switch location.authorization {
        case .notDetermined:
            settingsStore.settings.locationMetadataEnabled = true
            environment.applyLocationIntent(isForeground: true)
        case .denied, .restricted:
            // Nothing in the app can grant this back, so the honest move is to open the
            // one place that can.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            settingsStore.settings.locationMetadataEnabled.toggle()
            environment.applyLocationIntent(isForeground: true)
        }
    }

    // MARK: - Controls

    /// One enormous button. Protect joins it only while a recording is running, because
    /// there is nothing to protect before that — and it stays a distinct, quieter shape
    /// so the two are never confused at a glance.
    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                noteInteraction()
                Task { await recording.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: recording.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: isLandscape ? 24 : 32, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key: recording.isRecording ? "action.stop" : "action.start")
                            .font(.system(size: isLandscape ? 20 : 26, weight: .heavy))
                        if !isLandscape {
                            Text(key: recording.isRecording ? "record.cta.stop_hint" : "record.cta.start_hint")
                                .font(.system(size: 14, weight: .regular))
                                .opacity(0.85)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(
                fill: recording.isRecording ? Theme.textPrimary : Theme.coral,
                height: controlHeight
            ))
            .disabled(capture.status.mode == .unavailable)
            .accessibilityLabel(Text(key: recording.isRecording ? "action.stop" : "action.start"))
            .accessibilityHint(Text(key: recording.isRecording ? "a11y.stop_hint" : "a11y.start_hint"))

            Button {
                protect()
            } label: {
                Label(
                    title: { Text(key: protectFlash ? "action.protected" : "action.protect") },
                    icon: { Image(systemName: protectFlash ? "checkmark.shield.fill" : "shield.lefthalf.filled") }
                )
            }
            .buttonStyle(SoftButtonStyle(
                fill: protectFlash ? Theme.success : Theme.coralSoft,
                foreground: protectFlash ? .white : Theme.coral,
                height: isLandscape ? Theme.compactControlHeight : 62,
                font: .system(size: 19, weight: .bold)
            ))
            .disabled(!recording.isRecording)
            .opacity(recording.isRecording ? 1 : 0.55)
            .accessibilityHint(Text(key: "a11y.protect_hint"))
        }
    }

    // MARK: - Drive stats

    private var driveStats: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(titleKey: "record.stats")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatCard(
                    titleKey: "detail.duration",
                    value: Format.duration(recording.elapsed),
                    systemImage: "clock.fill",
                    accent: .orange
                )
                StatCard(
                    titleKey: "detail.distance",
                    value: distanceValue,
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill",
                    accent: .blue
                )
                StatCard(
                    titleKey: "stats.storage_free",
                    value: Format.bytes(storage.snapshot.freeBytes),
                    systemImage: "internaldrive.fill",
                    accent: .teal,
                    // The figure a driver actually wants from free space is how long it
                    // is worth, so it travels with it rather than taking a tile of its own.
                    footnote: L10n.t("stats.remaining", Format.duration(remainingRecordingTime))
                )
                StatCard(
                    titleKey: "detail.protected_events",
                    value: "\(protectedEventCount)",
                    systemImage: "checkmark.shield.fill",
                    accent: .coral
                )
            }

            // Thermal throttling changes what is being written to disk. It is shown only
            // when it actually deviates: a permanent quality row would be read as noise.
            if thermal.currentAction != .none {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 14, weight: .bold))
                    Text(verbatim: L10n.t("stats.quality_reduced", L10n.t(thermal.effectiveQuality.titleKey)))
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Theme.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pastelCard(.orange, padding: 12)
            }
        }
    }

    // MARK: - Derived values

    private var distanceValue: String {
        let kilometres = currentSession?.distanceKilometres ?? 0
        return String(format: "%.1f km", kilometres)
    }

    private var currentSession: DriveSession? {
        guard let id = recording.currentSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    private var protectedEventCount: Int {
        sessions.reduce(0) { $0 + $1.activeEvents.count }
    }

    private var remainingRecordingTime: TimeInterval {
        storage.snapshot.estimatedRemainingRecording(
            quality: thermal.effectiveQuality,
            limit: settingsStore.settings.storageLimit,
            dualCamera: capture.status.isDual
        )
    }

    // MARK: - Actions

    /// Feedback for a manual Protect lives entirely on the button — a colour change, a
    /// label change and a haptic. No alert, no banner: a dialog in front of the road is
    /// the last thing a driver needs, and it would have to be dismissed at exactly the
    /// wrong moment.
    private func protect() {
        guard recording.protectNow(origin: .manual) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.15)) { protectFlash = true }
        noteInteraction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeIn(duration: 0.4)) { protectFlash = false }
        }
    }

    /// Any touch resets the countdown to the discreet screen.
    private func noteInteraction() {
        lastInteraction = Date()
        scheduleDiscreet()
    }

    private func scheduleDiscreet() {
        discreetTimer?.invalidate()
        guard let interval = ScreenDimmer.countdown(
            delay: settingsStore.settings.discreetDelay,
            isRecording: recording.isRecording
        ) else { return }
        discreetTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in enterDiscreet() }
        }
    }

    /// Going dark is two things, and the second one is the point: the cameras stop being
    /// drawn *and* the backlight comes down. Removing the picture alone still leaves a
    /// lamp on the windscreen at night.
    ///
    /// Neither touches the capture. The session keeps running, the writers keep writing,
    /// and the only thing that changed is what the glass emits.
    private func enterDiscreet() {
        dimmer.enter(whileRecording: recording.isRecording)
        discreetTimer?.invalidate()
    }

    private func exitDiscreet() {
        dimmer.exit()
        noteInteraction()
    }
}
