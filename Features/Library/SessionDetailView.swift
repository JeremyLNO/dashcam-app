import AVKit
import SwiftUI

/// One drive, played back.
///
/// Road and cabin are kept in sync by construction: instead of two players nudged toward
/// each other with periodic seeks, both tracks live in a single composition driven by a
/// single `AVPlayer`. There is no drift to correct because there is only one clock.
struct SessionDetailView: View {
    let session: DriveSession

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @EnvironmentObject private var storage: StorageManager

    enum ViewMode: String, CaseIterable, Identifiable {
        case both
        case road
        case cabin

        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .both: return "player.mode.both"
            case .road: return "player.mode.road"
            case .cabin: return "player.mode.cabin"
            }
        }
    }

    @State private var mode: ViewMode = .both
    @State private var player = AVPlayer()
    @State private var isPreparing = true
    @State private var preparationFailed = false
    @State private var showExport = false
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                playerSurface
                modePicker
                metadata
                actions
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(Text(verbatim: Format.time(session.startedAt)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mode) { await prepare() }
        .onDisappear { player.pause() }
        .sheet(isPresented: $showExport) {
            ExportSheet(session: session)
                .environmentObject(environment)
                .environmentObject(subscriptions)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: .export)
                .environmentObject(environment)
                .environmentObject(subscriptions)
        }
    }

    // MARK: - Player

    private var playerSurface: some View {
        ZStack {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .opacity(isPreparing || preparationFailed ? 0.15 : 1)

            if isPreparing {
                ProgressView().tint(Theme.textSecondary)
            } else if preparationFailed {
                CameraUnavailableView(messageKey: "player.unavailable", systemImage: "exclamationmark.triangle")
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var modePicker: some View {
        Picker(selection: $mode) {
            ForEach(availableModes) { mode in
                Text(key: mode.titleKey).tag(mode)
            }
        } label: {
            Text(key: "player.mode")
        }
        .pickerStyle(.segmented)
    }

    private var availableModes: [ViewMode] {
        var modes: [ViewMode] = []
        if !session.rearSegments.isEmpty && !session.frontSegments.isEmpty { modes.append(.both) }
        if !session.rearSegments.isEmpty { modes.append(.road) }
        if !session.frontSegments.isEmpty { modes.append(.cabin) }
        return modes.isEmpty ? [.road] : modes
    }

    // MARK: - Info

    private var metadata: some View {
        VStack(spacing: 10) {
            infoRow(titleKey: "detail.date", value: Format.date(session.startedAt))
            infoRow(titleKey: "detail.start", value: Format.time(session.startedAt))
            infoRow(titleKey: "detail.duration", value: Format.duration(session.duration))
            infoRow(titleKey: "detail.size", value: Format.bytes(session.storageSize))
            infoRow(titleKey: "detail.segments", value: "\(session.segments.count)")
            infoRow(titleKey: "detail.quality", value: L10n.t(session.quality.titleKey))
            if session.hasProtectedContent {
                infoRow(
                    titleKey: "detail.protected_events",
                    value: "\(session.protectedEvents.filter(\.isActive).count)",
                    tint: Theme.warning
                )
            }
        }
        .dashcamCard()
    }

    private func infoRow(titleKey: String, value: String, tint: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(key: titleKey)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(verbatim: value)
                .font(Theme.body)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                // The paywall is opened here rather than inside the export sheet so the
                // user never sees export options they cannot use.
                if subscriptions.state.canExport { showExport = true } else { showPaywall = true }
            } label: {
                Label(
                    title: { Text(key: "action.export") },
                    icon: { Image(systemName: subscriptions.state.canExport ? "square.and.arrow.up" : "lock.fill") }
                )
            }
            .buttonStyle(DriverButtonStyle(fill: Theme.accent))
            .accessibilityIdentifier("exportButton")

            Button {
                environment.protection.setProtection(!session.hasProtectedContent, for: session)
            } label: {
                Label(
                    title: { Text(key: session.hasProtectedContent ? "action.unprotect" : "action.protect") },
                    icon: { Image(systemName: session.hasProtectedContent ? "shield.slash" : "shield.lefthalf.filled") }
                )
            }
            .buttonStyle(DriverButtonStyle(fill: Theme.surfaceElevated, isProminent: false))

            Button(role: .destructive) {
                environment.index.deleteSession(session)
                storage.refresh()
            } label: {
                Label(title: { Text(key: "library.delete.action") }, icon: { Image(systemName: "trash") })
            }
            .buttonStyle(DriverButtonStyle(fill: Theme.surface, foreground: Theme.accent, isProminent: false))
            .disabled(session.hasProtectedContent)
        }
    }

    // MARK: - Preparation

    private func prepare() async {
        isPreparing = true
        preparationFailed = false
        player.pause()

        let rear = session.rearSegments
        let front = session.frontSegments
        let effectiveMode = availableModes.contains(mode) ? mode : (availableModes.first ?? .road)

        do {
            let built: BuiltComposition
            switch effectiveMode {
            case .both:
                built = try await SessionComposition.pictureInPicture(rear: rear, front: front, includeAudio: true)
            case .road:
                built = try await SessionComposition.singleWithLayout(segments: rear, includeAudio: true)
            case .cabin:
                built = try await SessionComposition.singleWithLayout(segments: front, includeAudio: false)
            }

            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            player.replaceCurrentItem(with: item)
            isPreparing = false
        } catch {
            Log.export.error("Playback preparation failed: \(error.localizedDescription, privacy: .public)")
            preparationFailed = true
            isPreparing = false
        }
    }
}
