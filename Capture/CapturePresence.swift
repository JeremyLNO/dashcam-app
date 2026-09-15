import Foundation

/// Whether the cameras should be running at this moment.
///
/// They used to run for as long as the app was in the foreground — including while the
/// driver was sitting in the library watching footage back. Two cameras filming a pocket,
/// at full frame rate, to feed a preview nobody is looking at.
///
/// That is a battery and heat cost on its own, and it is also the leading explanation for a
/// defect reported from the car: **the two-up playback came back black while each camera
/// played fine on its own.** Playing road and cabin together decodes two streams at once;
/// doing it while a multi-camera capture session holds the video pipeline asks the phone
/// for more simultaneous work than it has. One stream fits in what is left, two do not, and
/// nothing anywhere reports a refusal — the frames simply never arrive and the layer stays
/// its background colour, which is black.
///
/// So the cameras are asked for only when something needs them: a drive being recorded, or
/// the screen that shows what they see.
enum CapturePresence {
    static func shouldRun(isRecording: Bool, isShowingCameras: Bool, isForeground: Bool) -> Bool {
        // iOS suspends capture in the background whatever the app asks for; asking anyway
        // only spends the wake-up.
        guard isForeground else { return false }
        // A drive outranks everything. Switching to the library mid-drive must not stop the
        // recording — that would be a far worse defect than the one this fixes.
        return isRecording || isShowingCameras
    }
}
