import SwiftUI
import UIKit

/// Picks what to export and where to send it.
///
/// Reachable only when `SubscriptionState.canExport` is true — during the free trial the
/// detail screen routes to the paywall instead, so this sheet never has to say no.
struct ExportSheet: View {
    let session: DriveSession

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @EnvironmentObject private var exporter: ExportManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ExportMode = .rear
    @State private var style: ExportStyle = .original
    @State private var scope: ExportScope = .wholeDrive
    /// Off unless asked for: a watermark changes the image, and the recording's whole
    /// value is being an untouched original.
    @State private var watermark = false
    @State private var customStart: Double = 0
    @State private var customDuration: Double = 60
    @State private var includeProof = false
    @State private var exportedURLs: [URL] = []
    @State private var isSharing = false
    @State private var errorMessage: String?
    @State private var savedToPhotos = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $mode) {
                        ForEach(availableModes) { mode in
                            Text(key: mode.titleKey).tag(mode)
                        }
                    } label: {
                        Text(key: "export.camera")
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text(key: "export.camera")
                }

                Section {
                    Picker(selection: $scope) {
                        ForEach(availableScopes) { scope in
                            Text(key: scope.titleKey).tag(scope)
                        }
                    } label: {
                        Text(key: "export.scope")
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("exportScope")

                    if scope == .custom {
                        customRangeControls
                    }
                } header: {
                    Text(key: "export.scope")
                }

                Section {
                    Picker(selection: $style) {
                        ForEach(ExportStyle.allCases) { style in
                            Text(key: style.titleKey).tag(style)
                        }
                    } label: {
                        Text(key: "export.style")
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text(key: "export.style")
                } footer: {
                    Text(key: "export.style.footer")
                }

                Section {
                    Toggle(isOn: $watermark) {
                        Text(key: "export.watermark")
                    }
                    .accessibilityIdentifier("watermarkToggle")
                } footer: {
                    Text(key: watermark && style == .original ? "export.watermark.footer.reencode" : "export.watermark.footer")
                }

                Section {
                    Toggle(isOn: $includeProof) {
                        Text(key: "export.proof")
                    }
                    .accessibilityIdentifier("proofToggle")
                } footer: {
                    Text(key: "export.proof.footer")
                }

                Section {
                    if exporter.isExporting {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: exporter.progress)
                            Text(verbatim: "\(Int(exporter.progress * 100)) %")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    } else {
                        Button {
                            Task { await runExport() }
                        } label: {
                            Label(
                                title: { Text(key: "export.start") },
                                icon: { Image(systemName: "square.and.arrow.up") }
                            )
                        }
                        .accessibilityIdentifier("startExportButton")
                    }

                    if !exportedURLs.isEmpty {
                        Button {
                            isSharing = true
                        } label: {
                            Label(title: { Text(key: "export.share") }, icon: { Image(systemName: "square.and.arrow.up.on.square") })
                        }
                        Button {
                            Task { await saveToPhotos() }
                        } label: {
                            Label(
                                title: { Text(key: savedToPhotos ? "export.saved_to_photos" : "export.save_to_photos") },
                                icon: { Image(systemName: savedToPhotos ? "checkmark.circle.fill" : "photo.on.rectangle") }
                            )
                        }
                        .disabled(savedToPhotos)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .navigationTitle(Text(key: "export.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(key: "common.close") }
                }
            }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: exportedURLs)
            }
            .onAppear { mode = availableModes.first ?? .rear }
        }
    }

    /// A drive shorter than a minute has no meaningful "last 30 seconds".
    private var availableScopes: [ExportScope] {
        ExportScope.allCases.filter { scope in
            switch scope {
            case .lastThirtySeconds: return session.duration > 30
            case .lastMinute: return session.duration > 60
            default: return true
            }
        }
    }

    private var customRangeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(L10n.t("export.range.start")): \(Format.duration(customStart))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Slider(value: $customStart, in: 0...max(1, session.duration - 1))
                    .onChange(of: customStart) { _, _ in clampCustomRange() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(L10n.t("export.range.duration")): \(Format.duration(customDuration))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Slider(value: $customDuration, in: 5...max(6, session.duration))
                    .onChange(of: customDuration) { _, _ in clampCustomRange() }
            }
        }
    }

    /// Keeps the window inside the drive: a start plus a duration that ran past the end
    /// would export a clip shorter than the one the sliders show.
    private func clampCustomRange() {
        let maximum = max(1, session.duration)
        customStart = min(customStart, maximum - 1)
        customDuration = min(customDuration, maximum - customStart)
    }

    private var customClip: SessionComposition.ClipRange? {
        guard scope == .custom else { return nil }
        return SessionComposition.ClipRange(start: customStart, duration: customDuration)
    }

    private var availableModes: [ExportMode] {
        let hasRear = !session.rearSegments.isEmpty
        let hasFront = !session.frontSegments.isEmpty
        var modes: [ExportMode] = []
        if hasRear { modes.append(.rear) }
        if hasFront { modes.append(.front) }
        if hasRear && hasFront { modes.append(contentsOf: [.both, .pictureInPicture]) }
        return modes
    }

    private func runExport() async {
        errorMessage = nil
        savedToPhotos = false
        do {
            exportedURLs = try await exporter.export(
                session: session,
                mode: mode,
                style: style,
                clip: scope.clip(driveDuration: session.duration, custom: customClip),
                includeProof: includeProof,
                watermark: watermark
            )
        } catch {
            exportedURLs = []
            errorMessage = (error as? ExportError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveToPhotos() async {
        do {
            for url in exportedURLs {
                try await exporter.saveToPhotoLibrary(url)
            }
            savedToPhotos = true
        } catch {
            errorMessage = (error as? ExportError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// `UIActivityViewController` bridge — AirDrop, Files, Messages, everything iOS offers.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
