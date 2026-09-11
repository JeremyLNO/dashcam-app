import AVFoundation
import Foundation
import Photos
import UIKit

enum ExportMode: String, CaseIterable, Identifiable, Sendable {
    case rear
    case front
    case both
    case pictureInPicture

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .rear: return "export.mode.rear"
        case .front: return "export.mode.front"
        case .both: return "export.mode.both"
        case .pictureInPicture: return "export.mode.pip"
        }
    }
}

enum ExportStyle: String, CaseIterable, Identifiable, Sendable {
    /// Bit-for-bit the recorded footage, just concatenated. No overlay, no re-encode.
    case original
    /// Re-encoded with the metadata stamp burned in.
    case withInformation

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .original: return "export.style.original"
        case .withInformation: return "export.style.with_info"
        }
    }
}

enum ExportError: LocalizedError, Equatable {
    case subscriptionRequired
    case noFootage
    case compositionFailed
    case exportFailed(String)
    case photoLibraryDenied

    var errorDescription: String? {
        switch self {
        case .subscriptionRequired: return L10n.t("export.error.subscription")
        case .noFootage: return L10n.t("export.error.no_footage")
        case .compositionFailed: return L10n.t("export.error.composition")
        case .exportFailed(let detail): return detail
        case .photoLibraryDenied: return L10n.t("export.error.photos_denied")
        }
    }
}

/// Renders footage out of the app.
///
/// Export is the one thing the subscription actually buys, so the entitlement check lives
/// here as well as in the UI: a code path that reaches `ExportManager` without going
/// through the paywall still cannot produce a file.
@MainActor
final class ExportManager: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?

    private let index: SessionIndex
    private let subscriptions: SubscriptionManager
    private let registry: ActiveFileRegistry
    private var progressTimer: Timer?

    init(index: SessionIndex, subscriptions: SubscriptionManager, registry: ActiveFileRegistry) {
        self.index = index
        self.subscriptions = subscriptions
        self.registry = registry
    }

    // MARK: - Entry point

    /// Produces one file per requested camera (two for `.both`, one otherwise).
    func export(session: DriveSession, mode: ExportMode, style: ExportStyle) async throws -> [URL] {
        guard subscriptions.state.canExport else { throw ExportError.subscriptionRequired }

        let rear = session.rearSegments
        let front = session.frontSegments
        guard !rear.isEmpty || !front.isEmpty else { throw ExportError.noFootage }

        let reserved = (rear + front).map(\.relativePath)
        registry.reserve(reserved)
        defer { registry.release(reserved) }

        isExporting = true
        progress = 0
        lastError = nil
        defer {
            isExporting = false
            progressTimer?.invalidate()
            progressTimer = nil
        }

        do {
            switch mode {
            case .rear:
                return [try await renderSingle(segments: rear, session: session, style: style, label: "road")]
            case .front:
                return [try await renderSingle(segments: front, session: session, style: style, label: "cabin")]
            case .both:
                var urls: [URL] = []
                if !rear.isEmpty { urls.append(try await renderSingle(segments: rear, session: session, style: style, label: "road")) }
                if !front.isEmpty { urls.append(try await renderSingle(segments: front, session: session, style: style, label: "cabin")) }
                return urls
            case .pictureInPicture:
                guard !rear.isEmpty, !front.isEmpty else { throw ExportError.noFootage }
                return [try await renderPictureInPicture(rear: rear, front: front, session: session, style: style)]
            }
        } catch let error as ExportError {
            lastError = error.errorDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - Single camera

    private func renderSingle(segments: [VideoSegment], session: DriveSession, style: ExportStyle, label: String) async throws -> URL {
        guard !segments.isEmpty else { throw ExportError.noFootage }
        let outputURL = makeOutputURL(session: session, suffix: label, style: style)

        switch style {
        case .original:
            // Passthrough: no re-encode, so the exported file carries exactly the pixels
            // that were recorded.
            let built = try await SessionComposition.single(segments: segments, includeAudio: true)
            if built.hasMixedGeometry {
                // The phone was turned mid-drive, so the segments are not all the same
                // shape. Passthrough cannot reconcile that — it would hand a player one
                // track whose sample dimensions change part-way through. Compositing into
                // the dominant frame size is the only output that plays correctly, so the
                // "original" export re-encodes in this one case.
                let laid = try await SessionComposition.singleWithLayout(segments: segments, includeAudio: true)
                try await runExport(composition: laid.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: laid.videoComposition, outputURL: outputURL)
            } else {
                try await runExport(composition: built.composition, preset: AVAssetExportPresetPassthrough, videoComposition: nil, outputURL: outputURL)
            }
        case .withInformation:
            let built = try await SessionComposition.singleWithLayout(segments: segments, includeAudio: true)
            if let videoComposition = built.videoComposition {
                attachOverlay(to: videoComposition, session: session, segments: segments, renderSize: built.renderSize, duration: built.duration.seconds)
            }
            try await runExport(composition: built.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: built.videoComposition, outputURL: outputURL)
        }
        return outputURL
    }

    // MARK: - Picture in picture

    private func renderPictureInPicture(rear: [VideoSegment], front: [VideoSegment], session: DriveSession, style: ExportStyle) async throws -> URL {
        let built = try await SessionComposition.pictureInPicture(rear: rear, front: front, includeAudio: true)
        if style == .withInformation, let videoComposition = built.videoComposition {
            attachOverlay(to: videoComposition, session: session, segments: rear, renderSize: built.renderSize, duration: built.duration.seconds)
        }
        let outputURL = makeOutputURL(session: session, suffix: "pip", style: style)
        try await runExport(composition: built.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: built.videoComposition, outputURL: outputURL)
        return outputURL
    }

    // MARK: - Overlay

    private func attachOverlay(to videoComposition: AVMutableVideoComposition, session: DriveSession, segments: [VideoSegment], renderSize: CGSize, duration: TimeInterval) {
        let settings = SettingsSnapshotProvider.current()
        guard settings.overlayEnabled, !settings.overlayFields.isEmpty else { return }
        guard let start = segments.first?.startDate else { return }

        let samples = index.locationSamples(sessionID: session.id, from: start, to: start.addingTimeInterval(duration))

        // Nearest-sample lookup. Samples land every two seconds, so a linear scan per
        // stamp would be O(n*m); the cursor makes it O(n+m) since both are time-ordered.
        var cursor = 0
        func nearest(_ date: Date) -> LocationSample? {
            guard !samples.isEmpty else { return nil }
            while cursor + 1 < samples.count, samples[cursor + 1].timestamp <= date { cursor += 1 }
            let candidate = samples[cursor]
            return abs(candidate.timestamp.timeIntervalSince(date)) < 10 ? candidate : nil
        }

        let stamps = OverlayRenderer.stamps(
            start: start,
            duration: duration,
            fields: settings.overlayFields,
            speedProvider: { nearest($0)?.speedKilometresPerHour },
            coordinateProvider: { date in
                guard let sample = nearest(date) else { return nil }
                return (sample.latitude, sample.longitude)
            }
        )

        if let built = OverlayRenderer.makeAnimationTool(renderSize: renderSize, stamps: stamps) {
            videoComposition.animationTool = built.tool
        }
    }

    // MARK: - Export plumbing

    private func runExport(composition: AVComposition, preset: String, videoComposition: AVVideoComposition?, outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.compositionFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition

        startProgressPolling(session)
        defer {
            progressTimer?.invalidate()
            progressTimer = nil
        }

        // The iOS 18 `export(to:as:)` replacement is not available on the 17.0 floor this
        // app targets, so the completion-handler form is used and bridged to async.
        // `AVAssetExportSession` is not Sendable; the completion runs on AVFoundation's
        // own queue and nothing else touches the session until it returns.
        nonisolated(unsafe) let exportSession = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exportSession.exportAsynchronously { continuation.resume() }
        }

        switch session.status {
        case .completed:
            progress = 1
        case .cancelled:
            throw ExportError.exportFailed(L10n.t("export.error.cancelled"))
        default:
            throw ExportError.exportFailed(session.error?.localizedDescription ?? L10n.t("export.error.unknown"))
        }
    }

    /// Polls `AVAssetExportSession.progress` for the UI.
    ///
    /// The timer fires on the main run loop and only ever *reads* `progress`, which is
    /// the one thing AVFoundation documents as safe to observe from another thread —
    /// hence the explicit unsafe capture rather than a spurious Sendable conformance.
    private func startProgressPolling(_ session: AVAssetExportSession) {
        nonisolated(unsafe) let exportSession = session
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            let value = Double(exportSession.progress)
            MainActor.assumeIsolated { self?.progress = value }
        }
    }

    private func makeOutputURL(session: DriveSession, suffix: String, style: ExportStyle) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let stamp = formatter.string(from: session.startedAt)
        let styleTag = style == .withInformation ? "-info" : ""
        return StorageLocations.exportsRoot.appendingPathComponent("Dashcam_\(stamp)_\(suffix)\(styleTag).mov")
    }

    // MARK: - Destinations

    /// Photos is opt-in, per export, and never automatic.
    func saveToPhotoLibrary(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photoLibraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

/// Lets `ExportManager` read the current overlay preferences without taking a dependency
/// on the whole settings object graph. Wired once at startup by `AppEnvironment`.
enum SettingsSnapshotProvider {
    nonisolated(unsafe) static var current: () -> RecordingSettings = { RecordingSettings() }
}
