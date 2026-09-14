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

/// How much of a drive to export.
enum ExportScope: String, CaseIterable, Identifiable, Sendable {
    case wholeDrive
    case lastThirtySeconds
    case lastMinute
    /// A window the user picked on the timeline.
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .wholeDrive: return "export.scope.whole"
        case .lastThirtySeconds: return "export.scope.30s"
        case .lastMinute: return "export.scope.1min"
        case .custom: return "export.scope.custom"
        }
    }

    /// Resolves to a clip window, or nil for the whole drive.
    func clip(driveDuration: TimeInterval, custom: SessionComposition.ClipRange?) -> SessionComposition.ClipRange? {
        switch self {
        case .wholeDrive:
            return nil
        case .lastThirtySeconds:
            return Self.tail(seconds: 30, of: driveDuration)
        case .lastMinute:
            return Self.tail(seconds: 60, of: driveDuration)
        case .custom:
            return custom
        }
    }

    /// A drive shorter than the requested tail exports whole, rather than producing an
    /// empty clip starting at a negative offset.
    private static func tail(seconds: TimeInterval, of duration: TimeInterval) -> SessionComposition.ClipRange? {
        guard duration > seconds else { return nil }
        return SessionComposition.ClipRange(start: duration - seconds, duration: seconds)
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
    private let attestation = AttestationService()
    private var progressTimer: Timer?

    init(index: SessionIndex, subscriptions: SubscriptionManager, registry: ActiveFileRegistry) {
        self.index = index
        self.subscriptions = subscriptions
        self.registry = registry
    }

    // MARK: - Entry point

    /// Produces one file per requested camera (two for `.both`, one otherwise), plus the
    /// proof manifest when it is asked for.
    func export(
        session: DriveSession,
        mode: ExportMode,
        style: ExportStyle,
        clip: SessionComposition.ClipRange? = nil,
        includeProof: Bool = false,
        watermark: Bool = false
    ) async throws -> [URL] {
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
            var urls: [URL] = []
            switch mode {
            case .rear:
                urls = [try await renderSingle(segments: rear, session: session, style: style, clip: clip, label: "road", watermark: watermark)]
            case .front:
                urls = [try await renderSingle(segments: front, session: session, style: style, clip: clip, label: "cabin", watermark: watermark)]
            case .both:
                if !rear.isEmpty { urls.append(try await renderSingle(segments: rear, session: session, style: style, clip: clip, label: "road", watermark: watermark)) }
                if !front.isEmpty { urls.append(try await renderSingle(segments: front, session: session, style: style, clip: clip, label: "cabin", watermark: watermark)) }
            case .pictureInPicture:
                guard !rear.isEmpty, !front.isEmpty else { throw ExportError.noFootage }
                urls = [try await renderPictureInPicture(rear: rear, front: front, session: session, style: style, watermark: watermark)]
            }
            if includeProof {
                let manifestURL = try writeProofManifest(for: session)
                urls.append(manifestURL)
                // The certificates cover the manifest, which is itself the thing that
                // covers every file: signing one digest binds the whole set, and a
                // verifier has one document to check rather than five.
                urls.append(contentsOf: await certify(manifestURL))
            }
            return urls
        } catch let error as ExportError {
            lastError = error.errorDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw ExportError.exportFailed(error.localizedDescription)
        }
    }

    /// Everything an insurer needs, in one gesture.
    ///
    /// The pieces existed separately — a trimmed export, a proof manifest, the position
    /// and speed of the moment, the file digests — and asking a shaken driver to assemble
    /// them was asking too much. This produces the clip around the incident, the manifest,
    /// and a one-page PDF that says what the clip is and hashes the files it travels with.
    func exportIncidentPack(session: DriveSession, event: ProtectedEvent?) async throws -> [URL] {
        guard subscriptions.state.canExport else { throw ExportError.subscriptionRequired }

        let clip = event.flatMap { clipRange(for: $0, in: session) }
        let mode: ExportMode = session.frontSegments.isEmpty ? .rear : .pictureInPicture
        var urls = try await export(
            session: session,
            mode: mode,
            style: .withInformation,
            clip: clip,
            includeProof: true
        )

        // Hashing happens on the files that are actually being handed over, not on the
        // recordings they came from: the recipient can only verify what they receive.
        var digests: [String: String] = [:]
        for url in urls {
            digests[url.lastPathComponent] = FileDigest.sha256(of: url)
        }

        let moment = event?.triggerDate ?? session.startedAt
        let nearby = index.locationSamples(
            sessionID: session.id,
            from: moment.addingTimeInterval(-20),
            to: moment.addingTimeInterval(20)
        )
        let sample = nearby.min { abs($0.timestamp.timeIntervalSince(moment)) < abs($1.timestamp.timeIntervalSince(moment)) }

        let report = IncidentReport(
            session: session,
            event: event,
            files: urls,
            digests: digests,
            locationAtEvent: sample,
            speedKilometresPerHour: sample?.speedKilometresPerHour
        )
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let reportURL = StorageLocations.exportsRoot
            .appendingPathComponent("Dashcam_incident_\(stamp.string(from: moment)).pdf")
        try report.write(to: reportURL)
        urls.append(reportURL)
        return urls
    }

    /// An event's window against the drive's own clock, clamped to footage that exists.
    private func clipRange(for event: ProtectedEvent, in session: DriveSession) -> SessionComposition.ClipRange? {
        let duration = session.duration
        guard duration > 0 else { return nil }
        let start = max(0, event.windowStart.timeIntervalSince(session.startedAt))
        let end = min(duration, event.windowEnd.timeIntervalSince(session.startedAt))
        guard end > start else { return nil }
        return SessionComposition.ClipRange(start: start, duration: end - start)
    }

    /// Signs and timestamps a manifest, when the driver asked for it.
    ///
    /// Nothing here can fail the export. A refused attestation, an authority that does not
    /// answer, a phone with no network — each costs its own certificate and nothing else.
    /// The alternative, an export that fails because a third party was unreachable, would
    /// lose the evidence to protect the proof of it.
    private func certify(_ manifestURL: URL) async -> [URL] {
        guard SettingsSnapshotProvider.current().certifyExports else { return [] }
        guard let digest = FileDigest.sha256(of: manifestURL),
              let digestData = Data(hexString: digest)
        else { return [] }

        var produced: [URL] = []

        do {
            let receipt = try await attestation.sign(digest: digestData)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let url = manifestURL.deletingPathExtension().appendingPathExtension("receipt.json")
            try encoder.encode(receipt).write(to: url, options: .atomic)
            produced.append(url)
        } catch {
            Log.export.error("Attestation unavailable: \(error.localizedDescription, privacy: .public)")
        }

        do {
            let token = try await TimestampAuthority.stamp(digest: digestData)
            let url = manifestURL.deletingPathExtension().appendingPathExtension("tsr")
            try token.write(to: url, options: .atomic)
            produced.append(url)
        } catch {
            Log.export.error("Timestamp unavailable: \(error.localizedDescription, privacy: .public)")
        }

        return produced
    }

    // MARK: - Single camera

    private func renderSingle(
        segments: [VideoSegment],
        session: DriveSession,
        style: ExportStyle,
        clip: SessionComposition.ClipRange?,
        label: String,
        watermark: Bool = false
    ) async throws -> URL {
        guard !segments.isEmpty else { throw ExportError.noFootage }
        let outputURL = makeOutputURL(session: session, suffix: label, style: style)

        // A watermark is drawn pixels, so it cannot ride on a passthrough copy: asking
        // for one turns the export into a re-encode, which is the honest cost of marking
        // an image and is stated in the sheet rather than discovered afterwards.
        if style == .original && watermark {
            let built = try await SessionComposition.singleWithLayout(segments: segments, includeAudio: true, clip: clip)
            if let videoComposition = built.videoComposition {
                attachOverlay(to: videoComposition, session: session, startDate: built.startDate, renderSize: built.renderSize, duration: built.duration.seconds, includeStamps: false, includeSignature: true)
            }
            try await runExport(composition: built.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: built.videoComposition, outputURL: outputURL)
            return outputURL
        }

        switch style {
        case .original:
            // Passthrough: no re-encode, so the exported file carries exactly the pixels
            // that were recorded.
            let built = try await SessionComposition.single(segments: segments, includeAudio: true, clip: clip)
            if built.hasMixedGeometry {
                // The phone was turned mid-drive, so the segments are not all the same
                // shape. Passthrough cannot reconcile that — it would hand a player one
                // track whose sample dimensions change part-way through. Compositing into
                // the dominant frame size is the only output that plays correctly, so the
                // "original" export re-encodes in this one case.
                let laid = try await SessionComposition.singleWithLayout(segments: segments, includeAudio: true, clip: clip)
                try await runExport(composition: laid.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: laid.videoComposition, outputURL: outputURL)
            } else {
                try await runExport(composition: built.composition, preset: AVAssetExportPresetPassthrough, videoComposition: nil, outputURL: outputURL)
            }
        case .withInformation:
            let built = try await SessionComposition.singleWithLayout(segments: segments, includeAudio: true, clip: clip)
            if let videoComposition = built.videoComposition {
                // The overlay is anchored on the clip's own first frame, not the drive's,
                // so a trimmed export still stamps the right wall-clock time.
                attachOverlay(to: videoComposition, session: session, startDate: built.startDate, renderSize: built.renderSize, duration: built.duration.seconds, includeStamps: true, includeSignature: watermark)
            }
            try await runExport(composition: built.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: built.videoComposition, outputURL: outputURL)
        }
        return outputURL
    }

    // MARK: - Picture in picture

    private func renderPictureInPicture(rear: [VideoSegment], front: [VideoSegment], session: DriveSession, style: ExportStyle, watermark: Bool = false) async throws -> URL {
        let built = try await SessionComposition.pictureInPicture(rear: rear, front: front, includeAudio: true)
        // A two-up export is always composited, so a watermark costs nothing extra here.
        if let videoComposition = built.videoComposition {
            attachOverlay(
                to: videoComposition, session: session, startDate: built.startDate,
                renderSize: built.renderSize, duration: built.duration.seconds,
                includeStamps: style == .withInformation, includeSignature: watermark
            )
        }
        let outputURL = makeOutputURL(session: session, suffix: "pip", style: style)
        try await runExport(composition: built.composition, preset: AVAssetExportPresetHighestQuality, videoComposition: built.videoComposition, outputURL: outputURL)
        return outputURL
    }

    // MARK: - Overlay

    private func attachOverlay(
        to videoComposition: AVMutableVideoComposition,
        session: DriveSession,
        startDate start: Date,
        renderSize: CGSize,
        duration: TimeInterval,
        includeStamps: Bool,
        includeSignature: Bool
    ) {
        let settings = SettingsSnapshotProvider.current()
        let wantsStamps = includeStamps && settings.overlayEnabled && !settings.overlayFields.isEmpty
        guard wantsStamps || includeSignature else { return }


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

        let stamps = wantsStamps ? OverlayRenderer.stamps(
            start: start,
            duration: duration,
            fields: settings.overlayFields,
            speedProvider: { nearest($0)?.speedKilometresPerHour },
            coordinateProvider: { date in
                guard let sample = nearest(date) else { return nil }
                return (sample.latitude, sample.longitude)
            }
        ) : []

        let signature = includeSignature ? SegmentMetadata.softwareDescription : nil
        if let built = OverlayRenderer.makeAnimationTool(renderSize: renderSize, stamps: stamps, signature: signature) {
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

    // MARK: - Proof

    /// Writes the evidence sidecar. Any segment still missing its digest is hashed now —
    /// normally they are hashed in the background as they are finalized, but a drive
    /// exported seconds after it ended may have caught up with that.
    private func writeProofManifest(for session: DriveSession) throws -> URL {
        for segment in session.segments where segment.sha256.isEmpty {
            let url = StorageLocations.absoluteURL(forRelativePath: segment.relativePath)
            if let digest = FileDigest.sha256(of: url) { segment.sha256 = digest }
        }
        index.save()

        let manifest = ProofManifest.make(
            for: session,
            locations: index.locationSamples(sessionID: session.id, from: session.startedAt, to: session.endedAt ?? Date())
        )
        let url = makeOutputURL(session: session, suffix: "proof", style: .original)
            .deletingPathExtension()
            .appendingPathExtension("json")
        try manifest.write(to: url)
        return url
    }

    // MARK: - Destinations

    /// Photos is opt-in, per export, and never automatic.
    ///
    /// Only video files are offered to Photos; the proof manifest is JSON and belongs in
    /// Files or an email, not in a photo library that would silently drop it.
    func saveToPhotoLibrary(_ url: URL) async throws {
        guard url.pathExtension.lowercased() != "json" else { return }
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
