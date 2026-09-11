import AVFoundation
import SwiftUI

/// The screen the driver looks at. Everything on it is readable at a glance, and the two
/// things you might need in an emergency — stop, and protect — are the two biggest
/// targets on the display.
struct RecordingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var recording: RecordingManager
    @EnvironmentObject private var capture: CaptureManager
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var storage: StorageManager
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var thermal: ThermalManager

    @State private var isDiscreet = false
    @State private var lastInteraction = Date()
    @State private var discreetTimer: Timer?
    @State private var protectFlash = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isDiscreet {
                DiscreetScreen(
                    isRecording: recording.isRecording,
                    elapsed: recording.elapsed,
                    status: capture.status,
                    freeSpace: storage.snapshot.freeBytes,
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
        .onDisappear { discreetTimer?.invalidate() }
        .onChange(of: settingsStore.settings.discreetDelay) { _, _ in scheduleDiscreet() }
        .alert(item: $recording.alert) { alert in
            Alert(
                title: Text(key: alert.titleKey),
                message: Text(key: alert.messageKey),
                dismissButton: .default(Text(key: "common.ok"))
            )
        }
    }

    // MARK: - Full screen

    private var content: some View {
        VStack(spacing: Theme.spacing) {
            header
            previews
            statusGrid
            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { noteInteraction() }
    }

    private var header: some View {
        HStack {
            RecordingIndicator(isRecording: recording.isRecording)
            Spacer()
            Text(verbatim: Format.duration(recording.elapsed))
                .font(Theme.timer(34))
                .foregroundStyle(recording.isRecording ? Theme.textPrimary : Theme.textTertiary)
                .accessibilityLabel(Text(key: "a11y.duration"))
                .accessibilityValue(Text(verbatim: Format.duration(recording.elapsed)))
        }
        .padding(.top, 4)
    }

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
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                if capture.status.frontActive {
                    CameraPreviewView(previewLayer: capture.frontPreviewLayer)
                        .frame(width: proxy.size.width * 0.30, height: proxy.size.width * 0.30 * 4 / 3)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        )
                        .padding(10)
                        .accessibilityLabel(Text(key: "a11y.front_preview"))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatusTile(
                titleKey: "status.rear",
                value: L10n.t(capture.status.rearActive ? capture.status.rearLensKey : "status.off"),
                systemImage: "car.rear.waves.up",
                tint: capture.status.rearActive ? Theme.positive : Theme.textTertiary
            )
            StatusTile(
                titleKey: "status.front",
                value: L10n.t(capture.status.frontActive ? "status.on" : "status.off"),
                systemImage: "person.fill.viewfinder",
                tint: capture.status.frontActive ? Theme.positive : Theme.textTertiary
            )
            StatusTile(
                titleKey: "status.gps",
                value: gpsValue,
                systemImage: "location.fill",
                tint: location.isAuthorized ? Theme.positive : Theme.textTertiary
            )
            StatusTile(
                titleKey: "status.free_space",
                value: Format.bytes(storage.snapshot.freeBytes),
                systemImage: "internaldrive",
                tint: storage.snapshot.isCriticallyLow ? Theme.accent : Theme.textSecondary
            )
            StatusTile(
                titleKey: "status.remaining",
                value: Format.duration(remainingRecordingTime),
                systemImage: "timer",
                tint: Theme.textSecondary
            )
            StatusTile(
                titleKey: "status.quality",
                value: L10n.t(thermal.effectiveQuality.titleKey),
                systemImage: "dial.high",
                tint: thermal.currentAction == .none ? Theme.textSecondary : Theme.warning
            )
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                noteInteraction()
                Task { await recording.toggle() }
            } label: {
                Label(
                    title: { Text(key: recording.isRecording ? "action.stop" : "action.start") },
                    icon: { Image(systemName: recording.isRecording ? "stop.fill" : "record.circle") }
                )
            }
            .buttonStyle(DriverButtonStyle(fill: recording.isRecording ? Theme.surfaceElevated : Theme.accent))
            .disabled(capture.status.mode == .unavailable)
            .accessibilityHint(Text(key: recording.isRecording ? "a11y.stop_hint" : "a11y.start_hint"))

            Button {
                protect()
            } label: {
                Label(
                    title: { Text(key: protectFlash ? "action.protected" : "action.protect") },
                    icon: { Image(systemName: protectFlash ? "checkmark.shield.fill" : "shield.lefthalf.filled") }
                )
            }
            .buttonStyle(DriverButtonStyle(fill: protectFlash ? Theme.positive : Theme.surfaceElevated, isProminent: false))
            .disabled(!recording.isRecording)
            .accessibilityHint(Text(key: "a11y.protect_hint"))
        }
    }

    // MARK: - Derived values

    private var gpsValue: String {
        guard location.isAuthorized else { return L10n.t("status.off") }
        if let speed = location.currentSpeedKilometresPerHour {
            return Format.speed(kilometresPerHour: speed)
        }
        return L10n.t(location.latest == nil ? "status.searching" : "status.on")
    }

    private var remainingRecordingTime: TimeInterval {
        storage.snapshot.estimatedRemainingRecording(
            quality: thermal.effectiveQuality,
            limit: settingsStore.settings.storageLimit,
            dualCamera: capture.status.isDual
        )
    }

    // MARK: - Actions

    private func protect() {
        guard recording.protectNow(origin: .manual) else { return }
        withAnimation { protectFlash = true }
        noteInteraction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { protectFlash = false }
        }
    }

    /// Any touch resets the countdown to the discreet screen.
    private func noteInteraction() {
        lastInteraction = Date()
        scheduleDiscreet()
    }

    private func scheduleDiscreet() {
        discreetTimer?.invalidate()
        guard let interval = settingsStore.settings.discreetDelay.interval else { return }
        discreetTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in isDiscreet = true }
        }
    }

    private func exitDiscreet() {
        isDiscreet = false
        noteInteraction()
    }
}
