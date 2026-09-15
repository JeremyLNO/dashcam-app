import AVFoundation
import Foundation

/// Why a composited frame came out black.
///
/// AVFoundation does not complain about an instruction list that leaves part of the
/// timeline uncovered, or about an instruction that draws no layer. It fills those moments
/// with the instruction's background colour — black — and says nothing at all. A player
/// showing footage and a player showing a black rectangle are the same object in the same
/// state, with the same `status`, and nothing in the log distinguishes them.
///
/// So the instruction list is checked before it is handed over, and what is wrong with it
/// is said out loud. This changes no pixels; it changes what a black frame leaves behind.
enum CompositionDiagnostics {
    enum Problem: Equatable, CustomStringConvertible {
        /// No instructions at all: AVFoundation renders the whole timeline black.
        case noInstructions
        /// The first instruction starts after the composition does.
        case doesNotStartAtZero(TimeInterval)
        /// A hole between two instructions.
        case gap(from: TimeInterval, to: TimeInterval)
        /// Two instructions covering the same instant, which makes the list invalid.
        case overlap(at: TimeInterval)
        /// An instruction covering no time at all.
        case emptyInstruction(at: TimeInterval)
        /// The instructions stop before the footage does.
        case uncoveredTail(from: TimeInterval, to: TimeInterval)
        /// An instruction with nothing to draw.
        case nothingToDraw(at: TimeInterval)

        var description: String {
            switch self {
            case .noInstructions:
                return "no instructions: the whole timeline renders black"
            case .doesNotStartAtZero(let start):
                return String(format: "nothing covers 0…%.3fs", start)
            case .gap(let from, let to):
                return String(format: "gap %.3f…%.3fs", from, to)
            case .overlap(let at):
                return String(format: "overlapping instructions at %.3fs", at)
            case .emptyInstruction(let at):
                return String(format: "zero-length instruction at %.3fs", at)
            case .uncoveredTail(let from, let to):
                return String(format: "tail %.3f…%.3fs uncovered", from, to)
            case .nothingToDraw(let at):
                return String(format: "instruction at %.3fs draws no layer", at)
            }
        }
    }

    /// Everything wrong with the list, in timeline order.
    ///
    /// Exact, with no tolerance: an instruction list that is one frame short of the footage
    /// is a list that was computed wrong, and a defect that only shows for 30 ms is still
    /// the one that shows for the whole drive on the next phone.
    static func problems(in videoComposition: AVVideoComposition, duration: CMTime) -> [Problem] {
        let instructions = videoComposition.instructions
        guard !instructions.isEmpty else { return [.noInstructions] }

        var found: [Problem] = []
        var cursor = CMTime.zero

        for instruction in instructions {
            let range = instruction.timeRange
            if CMTimeCompare(range.start, cursor) > 0 {
                found.append(
                    cursor == .zero
                        ? .doesNotStartAtZero(range.start.seconds)
                        : .gap(from: cursor.seconds, to: range.start.seconds)
                )
            } else if CMTimeCompare(range.start, cursor) < 0 {
                found.append(.overlap(at: range.start.seconds))
            }
            if range.duration.seconds <= 0 {
                found.append(.emptyInstruction(at: range.start.seconds))
            }
            if let concrete = instruction as? AVVideoCompositionInstruction,
               concrete.layerInstructions.isEmpty {
                found.append(.nothingToDraw(at: range.start.seconds))
            }
            cursor = CMTimeMaximum(cursor, range.end)
        }

        if CMTimeCompare(cursor, duration) < 0 {
            found.append(.uncoveredTail(from: cursor.seconds, to: duration.seconds))
        }
        return found
    }
}
