import AppIntents
import Foundation

/// The bridge between an intent and the running app.
///
/// Control Center runs its buttons from a widget extension — a separate process that has
/// no access to the app's objects. The intents below are compiled into **both** binaries
/// so the system can hand them to whichever side is running: in the extension the bridge
/// is empty and the intent only asks for the app to be opened; in the app, which fills
/// the bridge at launch, the same intent does the work.
///
/// It exists because the alternative — a shared app group carrying a "pending command"
/// flag — would add an entitlement, a provisioning change and a state that can get stuck,
/// to achieve exactly the same thing.
@MainActor
enum ControlBridge {
    static var startRecording: (() async -> Void)?
    static var stopRecording: (() async -> Void)?
    static var protectFootage: (() -> Void)?
}

/// Start a drive from Control Center, the Lock Screen or the Action button.
///
/// The app is opened on purpose, and it is not a shortcut taken lightly: iOS suspends
/// camera capture the moment an app leaves the foreground, so a control that claimed to
/// record without opening anything would be advertising something the system does not
/// allow.
@available(iOS 18.0, *)
struct ControlStartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dashcam recording"
    static var description = IntentDescription(
        "Opens Dashcam Pocket and starts recording the road and the cabin."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await ControlBridge.startRecording?()
        return .result()
    }
}

/// Protect what has just been filmed, without hunting for the button.
@available(iOS 18.0, *)
struct ControlProtectFootageIntent: AppIntent {
    static var title: LocalizedStringResource = "Protect Dashcam footage"
    static var description = IntentDescription(
        "Keeps the footage around this moment so the cleanup never deletes it."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ControlBridge.protectFootage?()
        return .result()
    }
}
