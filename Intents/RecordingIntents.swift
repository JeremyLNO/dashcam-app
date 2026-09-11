import AppIntents
import Foundation

/// Shortcuts actions for the three things a driver might want hands-free.
///
/// These exist mainly to make one automation possible: **When CarPlay connects → Start
/// Recording**. iOS will not let an app launch itself, so that automation, set up once by
/// the driver in the Shortcuts app, is the only way to get from "engine on" to "recording"
/// without touching the phone.
///
/// Every one of them opens the app, because iOS suspends camera capture outside the
/// foreground — an action that claimed to record in the background would be lying.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription(
        "Starts recording the road and the cabin. Opens Dashcam Pocket, because iOS only allows camera recording while the app is on screen."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let environment = AppEnvironment.shared else { return .result() }
        guard !environment.recording.isRecording else { return .result() }
        await environment.recording.start()
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description = IntentDescription("Stops the current recording and saves the drive.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let environment = AppEnvironment.shared else { return .result() }
        await environment.recording.stop()
        return .result()
    }
}

struct ProtectFootageIntent: AppIntent {
    static var title: LocalizedStringResource = "Protect Footage"
    static var description = IntentDescription(
        "Keeps the last five minutes and the next two, so the cleanup never deletes them."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared?.recording.protectNow(origin: .manual)
        return .result()
    }
}
