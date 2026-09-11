import Foundation
import os

/// One logger per subsystem. `os.Logger` is privacy-aware by default, which matters
/// here: nothing that identifies a place or a drive is ever interpolated publicly.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dashcam.lno.company"

    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let location = Logger(subsystem: subsystem, category: "location")
    static let motion = Logger(subsystem: subsystem, category: "motion")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let carplay = Logger(subsystem: subsystem, category: "carplay")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
