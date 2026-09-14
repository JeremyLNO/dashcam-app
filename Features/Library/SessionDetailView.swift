import AVFoundation
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
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

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

    /// Captured up front: after the delete the model is gone, and the id is all that is
    /// needed to finish the job.
    private var sessionID: UUID { session.id }

    @State private var mode: ViewMode = .both
    @State private var player = AVPlayer()
    @State private var isPreparing = true
    @State private var preparationFailed = false
    @State private var playheadOffset: TimeInterval = 0
    @State private var timeObserver: Any?
    /// Set by the Delete button. The deletion itself waits for `onDisappear`.
    @State private var isPendingDeletion = false
    @State private var showExport = false
    @State private var showPaywall = false
    @State private var isBuildingPack = false
    @State private var packFiles: [URL] = []
    @State private var packError: String?
    @State private var showPackShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                playerSurface
                modePicker
                timelineCard
                mapCard
                statsGrid
                actions
                incidentPackButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        // The screen writes the date itself, large. Repeating it in the bar would say the
        // same thing twice, six points apart.
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mode) { await prepare() }
        .onDisappear {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil

            // Deleting while this screen is still on screen would leave SwiftUI rendering
            // a model the store has just dropped, which SwiftData turns into a fatal
            // error ("this model instance was invalidated"). Waiting for the pop to
            // finish is exact, where a timed delay would only be a guess.
            guard isPendingDeletion else { return }
            environment.index.deleteSession(id: sessionID)
            storage.refresh()
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(session: session)
                .environmentObject(environment)
                .environmentObject(subscriptions)
        }
        .sheet(isPresented: $showPackShare) {
            ShareSheet(items: packFiles)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(context: .export)
                .environmentObject(environment)
                .environmentObject(subscriptions)
        }
    }

    // MARK: - Title

    /// The date, large, then the window the drive covers. A drive is remembered by when
    /// it happened, so that is what the screen leads with.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: Format.date(session.startedAt))
                .font(Theme.pageTitle)
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(verbatim: "\(Format.clock(session.startedAt)) – \(Format.clock(session.endedAt ?? session.startedAt))")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Player

    private var playerSurface: some View {
        ZStack {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                .opacity(isPreparing || preparationFailed ? 0.15 : 1)

            if isPreparing {
                ProgressView().tint(Theme.blue)
            } else if preparationFailed {
                CameraUnavailableView(messageKey: "player.unavailable", systemImage: "exclamationmark.triangle")
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                    .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .softShadow()
    }

    /// Three coloured buttons instead of a segmented control: which camera you are
    /// watching is the screen's main choice, and it deserves to look like one. Each mode
    /// keeps the colour it has everywhere else — road coral, cabin teal, both blue.
    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(availableModes) { item in
                Button {
                    mode = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: symbol(for: item))
                            .font(.system(size: 14, weight: .bold))
                        Text(key: item.titleKey)
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(mode == item ? .white : accent(for: item).strong)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                            .fill(mode == item ? accent(for: item).strong : accent(for: item).soft)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("mode-\(item.rawValue)")
            }
        }
    }

    private func accent(for mode: ViewMode) -> Accent {
        switch mode {
        case .road: return .coral
        case .both: return .blue
        case .cabin: return .teal
        }
    }

    private func symbol(for mode: ViewMode) -> String {
        switch mode {
        case .road: return "video.fill"
        case .both: return "rectangle.on.rectangle"
        case .cabin: return "person.fill"
        }
    }

    private var availableModes: [ViewMode] {
        var modes: [ViewMode] = []
        if !session.rearSegments.isEmpty && !session.frontSegments.isEmpty { modes.append(.both) }
        if !session.rearSegments.isEmpty { modes.append(.road) }
        if !session.frontSegments.isEmpty { modes.append(.cabin) }
        return modes.isEmpty ? [.road] : modes
    }

    // MARK: - Timeline

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(titleKey: "detail.timeline")
                Text(verbatim: Format.duration(session.duration))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            timeline
        }
        .dashcamCard()
    }

    private var timeline: some View {
        EventTimeline(
            duration: session.duration,
            marks: session.activeEvents.map { event in
                EventTimeline.Mark(
                    id: event.id,
                    offset: max(0, event.triggerDate.timeIntervalSince(session.startedAt)),
                    origin: event.origin,
                    magnitude: event.magnitude
                )
            },
            protectedSpans: protectedSpans,
            playheadOffset: playheadOffset,
            onSeek: { offset in
                player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                playheadOffset = offset
            }
        )
    }

    /// Protected windows expressed against the drive's own clock, for the shaded bands.
    private var protectedSpans: [ClosedRange<TimeInterval>] {
        session.segments
            .filter(\.isProtected)
            .map { segment in
                let start = max(0, segment.startDate.timeIntervalSince(session.startedAt))
                let end = max(start, segment.endDate.timeIntervalSince(session.startedAt))
                return start...end
            }
    }

    // MARK: - Map

    /// The route the drive took, or a card explaining why there is none.
    ///
    /// It used to draw nothing at all when a drive carried no positions — which is
    /// indistinguishable from a feature that does not exist. Jeremy asked for the route to
    /// be saved and shown; it had been both since the map shipped, but every drive he had
    /// recorded predated the location fix, so every drive showed an empty space where the
    /// answer should have been. A screen that cannot show something owes the reason.
    @ViewBuilder
    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(titleKey: "detail.route")
                if let kilometres = session.distanceKilometres, kilometres > 0 {
                    Text(verbatim: String(format: "%.1f km", kilometres))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if locationSamples.count > 1 {
                DriveMap(
                    samples: locationSamples,
                    events: session.activeEvents,
                    startedAt: session.startedAt,
                    onSelectEvent: { offset in
                        player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
                        playheadOffset = offset
                    }
                )
                Text(key: "detail.route.hint")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                missingRoute
            }
        }
        .dashcamCard()
    }

    /// Why this drive has no line on a map — and what to do about the next one.
    private var missingRoute: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: "location.slash", accent: .orange, isFilled: false, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(key: "detail.route.none")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(key: missingRouteReasonKey)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .pastelCard(.orange, padding: 14)
    }

    /// Three different silences, and they do not call for the same answer: a permission
    /// the app cannot grant itself, a setting the driver turned off, or a drive too short
    /// to have moved.
    private var missingRouteReasonKey: String {
        if !environment.location.isAuthorized { return "detail.route.none.permission" }
        if !settingsStore.settings.locationMetadataEnabled { return "detail.route.none.setting" }
        return "detail.route.none.drive"
    }

    // MARK: - Incident pack
    // MARK: - Incident pack

    /// One button for the whole evidence bundle: the clip around the incident, the proof
    /// manifest, and a PDF that says what they are. It is the moment the subscription
    /// earns itself, so a driver without one is shown the paywall rather than an error.
    private var incidentPackButton: some View {
        VStack(spacing: 8) {
            Button {
                if subscriptions.state.canExport {
                    Task { await buildIncidentPack() }
                } else {
                    showPaywall = true
                }
            } label: {
                HStack(spacing: 12) {
                    if isBuildingPack {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 20, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key: "action.incident_pack")
                            .font(.system(size: 18, weight: .bold))
                        Text(key: "detail.incident_pack.subtitle")
                            .font(.system(size: 13, weight: .regular))
                            .opacity(0.9)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PrimaryButtonStyle(fill: Theme.textPrimary, height: 74))
            .disabled(isBuildingPack)
            .accessibilityIdentifier("incidentPack")

            if let packError {
                Text(verbatim: packError)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func buildIncidentPack() async {
        isBuildingPack = true
        packError = nil
        defer { isBuildingPack = false }
        do {
            // The strongest event of the drive is the one a pack is about; without any,
            // the pack covers the whole drive.
            let event = session.activeEvents
                .sorted { $0.magnitude > $1.magnitude }
                .first
            packFiles = try await environment.exporter.exportIncidentPack(session: session, event: event)
            showPackShare = !packFiles.isEmpty
        } catch {
            packError = error.localizedDescription
        }
    }

    private var locationSamples: [LocationSample] {
        environment.index.locationSamples(
            sessionID: session.id,
            from: session.startedAt,
            to: session.endedAt ?? Date()
        )
    }

    // MARK: - Trip stats

    /// Six figures, each on its own colour. A drive is described by numbers that mean
    /// different things — a duration is not a file size — and giving each its own ground
    /// is what lets the eye find the one it came for without reading the labels.
    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(titleKey: "detail.stats")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                spacing: 10
            ) {
                statTile(titleKey: "detail.duration", value: Format.duration(session.duration),
                         systemImage: "clock.fill", accent: .orange)
                if let kilometres = session.distanceKilometres {
                    statTile(titleKey: "detail.distance", value: String(format: "%.1f km", kilometres),
                             systemImage: "location.fill", accent: .blue)
                }
                if session.peakGForce > 0 {
                    statTile(
                        titleKey: "detail.peak_g",
                        value: String(format: "%.2f g", session.peakGForce),
                        systemImage: "waveform.path.ecg",
                        // A peak past the impact threshold is the whole reason someone
                        // opened this drive: it gets the alarm colour, not the calm one.
                        accent: session.peakGForce >= ShockSensitivity.normal.thresholdG ? .coral : .violet
                    )
                }
                statTile(titleKey: "detail.size", value: Format.bytes(session.storageSize),
                         systemImage: "internaldrive.fill", accent: .teal)
                statTile(titleKey: "detail.quality", value: L10n.t(session.quality.titleKey),
                         systemImage: "sparkles", accent: .violet)
                statTile(
                    titleKey: "detail.protected_events",
                    value: "\(session.protectedEvents.filter(\.isActive).count)",
                    systemImage: "checkmark.shield.fill",
                    accent: session.hasProtectedContent ? .green : .blue
                )
            }

            // The cameras actually written to disk. Kept because it is the one line that
            // says whether the cabin really recorded — the question three builds were
            // spent answering by guesswork.
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.recordedCameras.count > 1 ? Theme.textSecondary : Theme.orange)
                Text(verbatim: session.cameraSummary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(session.recordedCameras.count > 1 ? Theme.textSecondary : Theme.orange)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statTile(titleKey: String, value: String, systemImage: String, accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(systemImage: systemImage, accent: accent, size: 38)
            Text(key: titleKey)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(accent, padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(L10n.t(titleKey)): \(value)"))
    }

    // MARK: - Actions

    /// Export leads, in blue. Protect keeps the coral it has everywhere. Delete is pale
    /// red text on a pale red ground — reachable, never mistakable for the other two.
    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                // The paywall is opened here rather than inside the export sheet so the
                // user never sees export options they cannot use.
                if subscriptions.state.canExport { showExport = true } else { showPaywall = true }
            } label: {
                actionLabel(
                    key: "action.export",
                    systemImage: subscriptions.state.canExport ? "square.and.arrow.up" : "lock.fill"
                )
            }
            .buttonStyle(SoftButtonStyle(fill: Theme.blue, foreground: .white, height: 60))
            .accessibilityIdentifier("exportButton")

            Button {
                environment.protection.setProtection(!session.hasProtectedContent, for: session)
            } label: {
                actionLabel(
                    key: session.hasProtectedContent ? "action.unprotect" : "action.protect",
                    systemImage: session.hasProtectedContent ? "shield.slash" : "checkmark.shield.fill"
                )
            }
            .buttonStyle(SoftButtonStyle(fill: Theme.coral, foreground: .white, height: 60))

            Button(role: .destructive) {
                isPendingDeletion = true
                dismiss()
            } label: {
                actionLabel(key: "library.delete.action", systemImage: "trash.fill")
            }
            .buttonStyle(SoftButtonStyle(fill: Theme.coralSoft, foreground: Theme.danger, height: 60))
            .disabled(session.hasProtectedContent)
            .opacity(session.hasProtectedContent ? 0.5 : 1)
            .accessibilityIdentifier("deleteDrive")
        }
    }

    private func actionLabel(key: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
            Text(key: key)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Preparation

    /// Drives the timeline playhead. Four times a second is enough to look continuous and
    /// cheap enough not to matter.
    private func installPlayheadObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            playheadOffset = max(0, time.seconds)
        }
    }

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
            installPlayheadObserver()
            isPreparing = false
        } catch {
            Log.export.error("Playback preparation failed: \(error.localizedDescription, privacy: .public)")
            preparationFailed = true
            isPreparing = false
        }
    }
}
