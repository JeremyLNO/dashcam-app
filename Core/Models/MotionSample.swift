import Foundation
import SwiftData

/// One second of accelerometer history for a drive.
///
/// Stored as a *peak per second* rather than every 50 Hz reading: a two-hour drive is
/// 7 200 rows this way and 360 000 the other, and what anyone ever wants to know about
/// a moment is how hard it was, not the exact waveform.
@Model
final class MotionSample {
    var sessionID: UUID
    var timestamp: Date
    /// Strongest total acceleration in that second, in g, gravity excluded.
    var peakG: Double

    var session: DriveSession?

    init(sessionID: UUID, timestamp: Date, peakG: Double) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.peakG = peakG
    }
}
