import Foundation
import UIKit

/// The evidence sidecar written next to a "proof mode" export.
///
/// The exported video is a re-encode or a concatenation — useful to watch, useless to
/// prove anything on its own. The manifest is what carries weight: it lists the original
/// segment files with their SHA-256 digests, so anyone holding the phone can re-hash the
/// untouched recordings and check they match what was handed over.
///
/// It deliberately claims nothing it cannot back up. There is no signature and no trusted
/// timestamp — that would need a service, and this app has no server by design. What it
/// says is "these are the files, this is what they hashed to, here is where and when the
/// device believed it was".
struct ProofManifest: Codable {
    struct SegmentRecord: Codable {
        let fileName: String
        let camera: String
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Double
        let fileSizeBytes: Int64
        let width: Int
        let height: Int
        let codec: String
        let sha256: String
        let isProtected: Bool
    }

    struct EventRecord: Codable {
        let triggeredAt: Date
        let origin: String
        let peakGForce: Double
        let windowStart: Date
        let windowEnd: Date
    }

    struct LocationRecord: Codable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let speedMetresPerSecond: Double
    }

    let manifestVersion: Int
    let generatedAt: Date
    let application: String
    let applicationVersion: String
    let deviceModel: String
    let systemVersion: String
    let driveID: String
    let driveStartedAt: Date
    let driveEndedAt: Date?
    let driveDurationSeconds: Double
    let distanceMetres: Double
    let peakGForce: Double
    let timeZoneIdentifier: String
    let segments: [SegmentRecord]
    let events: [EventRecord]
    let locations: [LocationRecord]
    let notes: String

    @MainActor
    static func make(for session: DriveSession, locations: [LocationSample]) -> ProofManifest {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let segments = session.segments
            .sorted { ($0.index, $0.cameraRaw) < ($1.index, $1.cameraRaw) }
            .map { segment in
                SegmentRecord(
                    fileName: (segment.relativePath as NSString).lastPathComponent,
                    camera: segment.cameraRaw,
                    startedAt: segment.startDate,
                    endedAt: segment.endDate,
                    durationSeconds: segment.duration,
                    fileSizeBytes: segment.fileSize,
                    width: segment.width,
                    height: segment.height,
                    codec: segment.codec,
                    sha256: segment.sha256,
                    isProtected: segment.isProtected
                )
            }

        return ProofManifest(
            manifestVersion: 1,
            generatedAt: Date(),
            application: "Dashcam Pocket",
            applicationVersion: "\(version) (\(build))",
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            driveID: session.id.uuidString,
            driveStartedAt: session.startedAt,
            driveEndedAt: session.endedAt,
            driveDurationSeconds: session.duration,
            distanceMetres: session.distanceMeters,
            peakGForce: session.peakGForce,
            timeZoneIdentifier: TimeZone.current.identifier,
            segments: segments,
            events: session.activeEvents.map { event in
                EventRecord(
                    triggeredAt: event.triggerDate,
                    origin: event.originRaw,
                    peakGForce: event.magnitude,
                    windowStart: event.windowStart,
                    windowEnd: event.windowEnd
                )
            },
            locations: locations.map {
                LocationRecord(
                    timestamp: $0.timestamp,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    speedMetresPerSecond: $0.speed
                )
            },
            notes: """
            The SHA-256 digests above are of the original recordings as written by the \
            device, before any export. Re-hash the files on the device to verify that the \
            exported footage matches what was recorded. This manifest is not signed and \
            carries no trusted timestamp: it records what the device observed, nothing more.
            """
        )
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
