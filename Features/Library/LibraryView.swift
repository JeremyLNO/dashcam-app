import SwiftData
import SwiftUI

/// The drives list, grouped by day.
///
/// One row per drive, not per file: a two-hour drive is forty segments on disk and one
/// thing in the user's head.
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
            .navigationTitle(Text(key: "tab.videos"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
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

    private var list: some View {
        List {
            Section {
                Picker(selection: $shelf) {
                    ForEach(Shelf.allCases) { shelf in
                        Text(key: shelf.titleKey).tag(shelf)
                    }
                } label: {
                    Text(key: "library.shelf")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("libraryShelf")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                storageSummary
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
            }

            if visibleSessions.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 30, leading: 16, bottom: 30, trailing: 16))
                }
            }

            ForEach(groupedByDay, id: \.key) { group in
                Section {
                    ForEach(group.value, id: \.id) { session in
                        row(for: session)
                    }
                } header: {
                    Text(verbatim: group.key)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
    }

    @ViewBuilder
    private func row(for session: DriveSession) -> some View {
        if isSelecting {
            Button {
                toggleSelection(session.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(session.id) ? Theme.accent : Theme.textTertiary)
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
                .tint(Theme.warning)
            }
        }
    }

    private var storageSummary: some View {
        HStack(spacing: 10) {
            summaryTile(titleKey: "library.summary.used", value: Format.bytes(storage.snapshot.dashcamBytes))
            summaryTile(titleKey: "library.summary.drives", value: "\(storage.snapshot.sessionCount)")
            summaryTile(titleKey: "library.summary.recorded", value: Format.duration(storage.snapshot.totalRecordedDuration))
        }
    }

    private func summaryTile(titleKey: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: value)
                .font(Theme.tileValue)
                .foregroundStyle(Theme.textPrimary)
            Text(key: titleKey)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(key: shelf == .protected ? "library.empty.protected.title" : "library.empty.title")
                .font(Theme.headline)
                .foregroundStyle(Theme.textSecondary)
            Text(key: shelf == .protected ? "library.empty.protected.subtitle" : "library.empty.subtitle")
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if sessions.isEmpty {
                EmptyView()
            } else {
                Button {
                    isSelecting.toggle()
                    selection.removeAll()
                } label: {
                    Text(key: isSelecting ? "common.done" : "common.select")
                }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button(role: .destructive) {
                    pendingDeletion = true
                } label: {
                    Text(key: "library.delete.action")
                }
                .disabled(selection.isEmpty)
            }
        }
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

/// One drive in the list.
struct SessionRow: View {
    let session: DriveSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: Format.time(session.startedAt))
                        .font(Theme.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if session.hasProtectedContent {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .accessibilityLabel(Text(key: "a11y.protected"))
                    }
                    // Only the causes worth spotting from the list: a manual protect is
                    // already implied by the shield.
                    ForEach(distinctAutomaticOrigins, id: \.self) { origin in
                        Image(systemName: origin.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(origin == .impact ? Theme.accent : Theme.warning)
                            .accessibilityLabel(Text(key: origin.titleKey))
                    }
                }
                Text(verbatim: subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text(verbatim: Format.duration(session.duration))
                .font(Theme.tileValue)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var distinctAutomaticOrigins: [ProtectionOrigin] {
        var seen: [ProtectionOrigin] = []
        for event in session.activeEvents where event.origin == .impact || event.origin == .harshBraking {
            if !seen.contains(event.origin) { seen.append(event.origin) }
        }
        return seen
    }

    private var subtitle: String {
        var parts = [L10n.t("library.segments", session.segmentCount)]
        if let kilometres = session.distanceKilometres {
            parts.append(String(format: "%.1f km", kilometres))
        }
        parts.append(Format.bytes(session.storageSize))
        return parts.joined(separator: " · ")
    }
}
