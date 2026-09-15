import Foundation

/// Keeps a two-camera configuration inside the hardware budget it has to fit in.
///
/// `AVCaptureMultiCamSession` publishes a `hardwareCost`, and the rule attached to it is
/// not advisory: **above 1.0 the session cannot run.** What it does instead is the worst
/// possible failure mode for a preview — it starts, reports itself running, raises no error
/// the app is listening for, and delivers no frames. The picture on screen is whatever was
/// there before, frozen.
///
/// The app measured that number from the first build and never once acted on it. Worse, it
/// pinned `activeVideoMinFrameDuration` *and* `Max` to 30 fps on both cameras, which is the
/// most expensive request available and also takes away the one lever AVFoundation has for
/// lowering the cost by itself. Whether a given phone landed above or below 1.0 then came
/// down to which formats happened to be picked and how warm it was — which is exactly what
/// « the cameras freeze quite often at launch » looks like from the driver's seat.
///
/// So the cost is read after the graph is built, and the configuration is walked down until
/// it fits. Frame rate first, because it is the cheapest thing to lose: a dashcam at 24 fps
/// is a dashcam; a dashcam showing a still image is not.
enum MultiCamBudget {
    /// Apple's limit. At or below, the session runs; above, it does not.
    static let limit: Float = 1.0

    /// What to give up, in order. 24 and 20 are still perfectly legible footage; 15 is the
    /// floor, below which motion on a road stops being continuous.
    static let frameRateLadder: [Int] = [30, 24, 20, 15]

    enum Step: Equatable {
        /// It fits. Nothing to do.
        case accept
        /// Try again at this frame rate.
        case lowerFrameRate(Int)
        /// Nothing left to give: one camera, at the driver's chosen rate.
        case dropCabinCamera
    }

    static func nextStep(cost: Float, currentFrameRate: Int) -> Step {
        guard cost > limit else { return .accept }
        guard let next = frameRateLadder.first(where: { $0 < currentFrameRate }) else {
            return .dropCabinCamera
        }
        return .lowerFrameRate(next)
    }

    /// A cost of exactly 1.0 is inside the budget, and phones do land there. Treating the
    /// boundary as a failure would shed a camera nobody needed to lose.
    static func fits(_ cost: Float) -> Bool { cost <= limit }
}
