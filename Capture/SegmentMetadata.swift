import AVFoundation
import CoreLocation
import Foundation
import UIKit

/// What each recorded file says about itself.
///
/// Until now a segment was a bare `.mov`: correct pixels, and not one word about where it
/// came from. Everything the app knew — when, where, on what — lived in its own database,
/// which is fine while the file stays in the app and worthless the moment it is handed to
/// an insurer, who receives a video like any other.
///
/// So the facts travel **inside** the file, in the standard QuickTime places: an insurer's
/// expert, `ffprobe`, `exiftool` and Photos all read them without knowing this app exists.
///
/// ⚠️ **None of this is proof.** Anyone can write the same fields with ffmpeg in ten
/// seconds. Metadata states provenance; it does not establish it. What establishes it is
/// the signature chain in `ProofManifest` — this is the part that makes a file *readable*,
/// not the part that makes it *trustworthy*, and the two must never be confused when
/// talking to a user.
enum SegmentMetadata {
    /// Custom keys live under the QuickTime `mdta` namespace, prefixed with the bundle's
    /// own reverse-DNS: that is the convention that keeps them from colliding with
    /// anyone else's, and it names the app in the file without pretending to prove it.
    static let keyPrefix = "com.crazybeelabs.dashcam"

    /// Written once, at the head of every segment.
    static func fileLevel(
        sessionID: UUID,
        camera: CameraPosition,
        segmentIndex: Int,
        startedAt: Date,
        location: CLLocation?
    ) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            item(identifier: .quickTimeMetadataCreationDate, value: iso8601.string(from: startedAt) as NSString),
            item(identifier: .quickTimeMetadataMake, value: "Apple" as NSString),
            item(identifier: .quickTimeMetadataModel, value: UIDevice.current.model as NSString),
            item(identifier: .quickTimeMetadataSoftware, value: softwareDescription as NSString),
            custom(key: "session", value: sessionID.uuidString as NSString),
            custom(key: "camera", value: camera.rawValue as NSString),
            custom(key: "segment", value: NSNumber(value: segmentIndex)),
            custom(key: "timezone", value: TimeZone.current.identifier as NSString),
        ]

        // A position is written only when there is one. An absent field is honest; a
        // zeroed one reads as "the Gulf of Guinea" to every tool that parses it.
        if let location {
            items.append(item(identifier: .quickTimeMetadataLocationISO6709, value: iso6709(location) as NSString))
            items.append(custom(key: "location.accuracy", value: NSNumber(value: location.horizontalAccuracy)))
            if location.speed >= 0 {
                items.append(custom(key: "location.speed", value: NSNumber(value: location.speed)))
            }
        }
        return items
    }

    /// The description of the timed track: one group of items per sample, carrying where
    /// the car was at that instant.
    ///
    /// This is what a dashcam is expected to produce — a position attached to a moment of
    /// footage rather than to the file as a whole. It is what lets anyone replay a drive
    /// and ask "where was I when this happened", including tools that never heard of us.
    static var timedSpecifications: [[String: Any]] {
        [
            [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                    AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                    kCMMetadataBaseDataType_UTF8 as String,
            ],
            [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier(for: "speed"),
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                    kCMMetadataBaseDataType_Float64 as String,
            ],
            [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier(for: "gforce"),
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                    kCMMetadataBaseDataType_Float64 as String,
            ],
        ]
    }

    /// One sample of the timed track.
    static func timedItems(location: CLLocation?, gForce: Double?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let location {
            items.append(item(identifier: .quickTimeMetadataLocationISO6709, value: iso6709(location) as NSString))
            if location.speed >= 0 {
                items.append(custom(key: "speed", value: NSNumber(value: location.speed)))
            }
        }
        if let gForce {
            items.append(custom(key: "gforce", value: NSNumber(value: gForce)))
        }
        return items
    }

    // MARK: - Pieces

    static func identifier(for key: String) -> String {
        "\(AVMetadataKeySpace.quickTimeMetadata.rawValue)/\(keyPrefix).\(key)"
    }

    static var softwareDescription: String {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Dashcam Pocket"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(name) \(version) (\(build))"
    }

    /// ISO 6709, the format QuickTime expects: signed degrees, fixed width, altitude in
    /// metres, terminated by a solidus.
    static func iso6709(_ location: CLLocation) -> String {
        String(
            format: "%+08.4f%+09.4f%+.1f/",
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.altitude
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func item(identifier: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        return item
    }

    private static func custom(key: String, value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: identifier(for: key))
        item.value = value
        return item
    }
}
