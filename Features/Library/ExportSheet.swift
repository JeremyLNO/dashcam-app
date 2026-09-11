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
            exportedURLs = try await exporter.export(session: session, mode: mode, style: style)
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
