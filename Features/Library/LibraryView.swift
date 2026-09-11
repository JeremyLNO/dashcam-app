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

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var pendingDeletion = false

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else {
                    list
                }
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
                storageSummary
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
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
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(key: "library.empty.title")
                .font(Theme.headline)
                .foregroundStyle(Theme.textSecondary)
            Text(key: "library.empty.subtitle")
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var groupedByDay: [(key: String, value: [DriveSession])] {
        let grouped = Dictionary(grouping: sessions) { Format.date($0.startedAt) }
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
        for session in sessions where selection.contains(session.id) {
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

    private var subtitle: String {
        let segments = L10n.t("library.segments", session.segments.count)
        return "\(segments) · \(Format.bytes(session.storageSize))"
    }
}
