import Foundation

/// Shared, pre-built formatters. Rebuilding a `DateFormatter` per row is a classic
/// source of scroll jank in a list of a few hundred segments.
enum Format {
    /// "01:23:45" for anything an hour or longer, "23:45" otherwise. Used for the big
    /// REC timer, so it must be monospaced-friendly and never change width mid-second.
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func gigabytes(_ value: Double) -> String {
        String(format: "%.1f GB", value)
    }

    /// "2.4 GB/h" — the storage cost shown next to each quality tier.
    static func gigabytesPerHour(_ value: Double) -> String {
        String(format: "%.1f", value) + " " + L10n.t("unit.gb_per_hour")
    }

    static func speed(kilometresPerHour: Double) -> String {
        String(format: "%.0f km/h", max(0, kilometresPerHour))
    }

    static func coordinate(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// Compact stamp burned into an exported frame, e.g. "12/09/2026 14:03:22".
    static func overlayStamp(_ date: Date, fields: OverlayFields) -> String {
        var parts: [String] = []
        if fields.contains(.date) { parts.append(dateFormatter.string(from: date)) }
        if fields.contains(.time) { parts.append(timeFormatter.string(from: date)) }
        return parts.joined(separator: "  ")
    }
}
