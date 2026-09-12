import SwiftData
import SwiftUI

/// The drives list, grouped by day.
///
/// One row per drive, not per file: a two-hour drive is forty segments on disk and one
/// thing in the user's head. The list is built to be scanned — the time of day is the
/// largest thing on a card, because "the one this morning" is how anyone looks for a
/// drive, and the badge saying why it was kept comes second.
struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var storage: StorageManager

    @Query(sort: \DriveSession.startedAt, order: .reverse) private var sessions: [DriveSession]

    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var gate = BiometricGate()

    /// Which shelf of the library is showing. Protected drives get their own, because
    /// "the one with the incident" is the drive anyone actually comes back for.
    enum Shelf: String, CaseIterable, Identifiable {
        case all
        case protected

        var id: String { rawValue }
        var titleKey: String { self == .all ? "library.shelf.all" : "library.shelf.protected" }
    }

    @State private var shelf: Shelf = .all
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var pendingDeletion = false

    var body: some View {
        NavigationStack {
            Group {
                if settingsStore.settings.requireBiometricUnlock && !gate.isUnlocked {
                    BiometricLockView(
                        onUnlock: { Task { await gate.unlock() } },
                        errorMessage: gate.lastError
                    )
                } else {
                    // The shelf picker lives outside this branch on purpose: putting it
                    // inside `list` meant an empty Protected shelf replaced the picker
                    // with the empty state, and there was no way back to All drives.
                    list
                }
            }
            .task(id: settingsStore.settings.requireBiometricUnlock) {
                guard settingsStore.settings.requireBiometricUnlock else {
                    gate.reset()
                    return
                }
                if !gate.isUnlocked { await gate.unlock() }
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                Text(key: "library.delete.confirm"),
                isPresented: $pendingDeletion,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Text(key: "library.delete.action")
                }
                Button(role: .cancel) { } label: { Text(key: "common.cancel") }
            } message: {
                Text(key: "library.delete.warning")
            }
        }
    }

    // MARK: - Content

    /// A `List` rather than a scroll view of cards, for one reason: swipe-to-delete and
    /// swipe-to-protect are worth more than the few points of padding it costs. The rows
    /// are dressed as cards instead.
    private var list: some View {
        List {
            Section {
                header
                    .plainRow(top: 6, bottom: 14)

                shelfPicker
                    .plainRow(bottom: 14)

                summaryRow
                    .plainRow(bottom: 8)
            }

            if visibleSessions.isEmpty {
                Section {
                    emptyState.plainRow(top: 30, bottom: 30)
                }
            }

            ForEach(groupedByDay, id: \.key) { group in
                Section {
                    ForEach(group.value, id: \.id) { session in
                        row(for: session)
                            .plainRow(top: 5, bottom: 5)
                    }
                } header: {
                    dayHeader(for: group)
                }
            }
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    /// The title, and the two controls that used to live in a navigation bar this screen
    /// no longer has: Select, and — while selecting — Delete.
    private var header: some View {
        PageHeader(titleKey: "tab.videos", subtitleKey: "library.subtitle") {
            if !sessions.isEmpty {
                HStack(spacing: 8) {
                    if isSelecting {
                        Button(role: .destructive) {
                            pendingDeletion = true
                        } label: {
                            pill(titleKey: "library.delete.action", systemImage: "trash",
                                 tint: Theme.danger, ground: Theme.coralSoft)
                        }
                        .buttonStyle(.plain)
                        .disabled(selection.isEmpty)
                        .opacity(selection.isEmpty ? 0.5 : 1)
                    }

                    Button {
                        isSelecting.toggle()
                        selection.removeAll()
                    } label: {
                        pill(
                            titleKey: isSelecting ? "common.done" : "common.select",
                            systemImage: isSelecting ? "checkmark" : "line.3.horizontal.decrease",
                            tint: Theme.blue,
                            ground: Theme.blueSoft
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("selectDrives")
                }
            }
        }
    }

    private func pill(titleKey: String, systemImage: String, tint: Color, ground: Color) -> some View {
        Label(
            title: { Text(key: titleKey) },
            icon: { Image(systemName: systemImage) }
        )
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Capsule().fill(ground))
    }

    /// A pill switch rather than the system segmented control: at this size the system
    /// one reads as a form field, and this is the screen's main filter.
    private var shelfPicker: some View {
        HStack(spacing: 4) {
            ForEach(Shelf.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { shelf = item }
                } label: {
                    Text(key: item.titleKey)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(shelf == item ? .white : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            Capsule().fill(shelf == item ? Theme.coral : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shelf == item ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.surfaceElevated))
        .accessibilityIdentifier("libraryShelf")
    }

    private var summaryRow: some View {
        HStack(spacing: 10) {
            summaryTile(
                titleKey: "library.summary.drives",
                value: "\(storage.snapshot.sessionCount)",
                systemImage: "car.fill",
                accent: .coral
            )
            summaryTile(
                titleKey: "library.summary.recorded",
                value: Format.duration(storage.snapshot.totalRecordedDuration),
                systemImage: "clock.fill",
                accent: .orange
            )
            summaryTile(
                titleKey: "library.summary.used",
                value: Format.bytes(storage.snapshot.dashcamBytes),
                systemImage: "internaldrive.fill",
                accent: .teal
            )
        }
    }

    private func summaryTile(titleKey: String, value: String, systemImage: String, accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(systemImage: systemImage, accent: accent, size: 34)
            Text(key: titleKey)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: value)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(accent, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private func dayHeader(for group: (key: String, value: [DriveSession])) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: relativeDayName(for: group.value.first?.startedAt))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(verbatim: group.key)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
        .listRowBackground(Color.clear)
    }

    /// "Today" and "Yesterday" carry the day better than a date does; anything older is
    /// named by its date alone, which the trailing label already shows.
    private func relativeDayName(for date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.t("library.day.today") }
        if calendar.isDateInYesterday(date) { return L10n.t("library.day.yesterday") }
        return date.formatted(.dateTime.weekday(.wide)).capitalized
    }

    @ViewBuilder
    private func row(for session: DriveSession) -> some View {
        if isSelecting {
            Button {
                toggleSelection(session.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selection.contains(session.id) ? Theme.coral : Theme.textTertiary)
                    SessionRow(session: session)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionRow")
        } else {
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                SessionRow(session: session)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionRow")
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    environment.index.deleteSession(session)
                    storage.refresh()
                } label: {
                    Label(title: { Text(key: "library.delete.action") }, icon: { Image(systemName: "trash") })
                }
                .disabled(session.hasProtectedContent)

                Button {
                    environment.protection.setProtection(!session.hasProtectedContent, for: session)
                } label: {
                    Label(
                        title: { Text(key: session.hasProtectedContent ? "action.unprotect" : "action.protect") },
                        icon: { Image(systemName: session.hasProtectedContent ? "shield.slash" : "shield") }
                    )
                }
                .tint(Theme.coral)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            IconBadge(systemImage: "film.stack", accent: .blue, isFilled: false, size: 72)
            Text(key: shelf == .protected ? "library.empty.protected.title" : "library.empty.title")
                .font(Theme.cardTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(key: shelf == .protected ? "library.empty.protected.subtitle" : "library.empty.subtitle")
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    /// Drives on the shelf currently selected.
    private var visibleSessions: [DriveSession] {
        shelf == .protected ? sessions.filter(\.hasProtectedContent) : sessions
    }

    private var groupedByDay: [(key: String, value: [DriveSession])] {
        let grouped = Dictionary(grouping: visibleSessions) { Format.date($0.startedAt) }
        // Dictionary order is undefined; re-sort by the first session's real date so days
        // do not shuffle between renders.
        return grouped
            .map { (key: $0.key, value: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { ($0.value.first?.startedAt ?? .distantPast) > ($1.value.first?.startedAt ?? .distantPast) }
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func deleteSelected() {
        for session in visibleSessions where selection.contains(session.id) {
            // Protection outranks a bulk delete: the user has to release it explicitly.
            guard !session.hasProtectedContent else { continue }
            environment.index.deleteSession(session)
        }
        selection.removeAll()
        isSelecting = false
        storage.refresh()
    }
}

private extension View {
    /// A list row that carries no list furniture: no separator, no grey ground, no inset
    /// of its own. Everything in this screen draws its own card.
    func plainRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: 18, bottom: bottom, trailing: 18))
    }
}

/// One drive in the list: a still from the road, the time it started, and the three
/// figures that describe it.
struct SessionRow: View {
    let session: DriveSession

    var body: some View {
        HStack(spacing: 12) {
            DriveThumbnail(session: session)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: Format.clock(session.startedAt))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if let badge {
                        Pill(text: L10n.t(badge.titleKey), accent: badge.accent, systemImage: badge.symbol)
                    }
                }

                HStack(spacing: 10) {
                    factLabel(systemImage: "clock", text: Format.duration(session.duration))
                    if let kilometres = session.distanceKilometres {
                        factLabel(systemImage: "location", text: String(format: "%.1f km", kilometres))
                    }
                    factLabel(systemImage: "doc", text: Format.bytes(session.storageSize))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
        )
        .softShadow()
        .accessibilityElement(children: .combine)
    }

    private func factLabel(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    /// One badge at most, and only when it says something the figures do not: why this
    /// drive was kept. An impact outranks a harsh brake, which outranks a manual protect.
    private var badge: (titleKey: String, accent: Accent, symbol: String)? {
        let origins = session.activeEvents.map(\.origin)
        if origins.contains(.impact) {
            return ("event.origin.impact", .coral, "exclamationmark.triangle.fill")
        }
        if origins.contains(.harshBraking) {
            return ("event.origin.braking", .orange, "exclamationmark.circle.fill")
        }
        if session.hasProtectedContent {
            return ("library.shelf.protected", .green, "checkmark.shield.fill")
        }
        return nil
    }
}
