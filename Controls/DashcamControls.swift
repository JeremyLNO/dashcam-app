import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center buttons.
///
/// Starting a dashcam is a gesture made with the engine running and the phone already in
/// its cradle: every second spent finding an app icon is a second of road not filmed.
/// Since iOS 18 that gesture can live in Control Center, on the Lock Screen, or on the
/// Action button — which is as close to a physical record button as an iPhone gets.
/// The extension itself targets iOS 18, so nothing here needs an availability branch —
/// and a `@main` whose body was wrapped in one produced a binary with no Swift entry
/// point at all, which App Store Connect rejects outright.
@main
struct DashcamControlBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingControl()
        ProtectFootageControl()
        DashcamStatusWidget()
    }
}

struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "company.lno.dashcam.control.start") {
            ControlWidgetButton(action: ControlStartRecordingIntent()) {
                Label("Record", systemImage: "record.circle")
            }
        }
        .displayName("Start Dashcam recording")
        .description("Opens Dashcam Pocket and starts filming the road and the cabin.")
    }
}

struct ProtectFootageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "company.lno.dashcam.control.protect") {
            ControlWidgetButton(action: ControlProtectFootageIntent()) {
                Label("Protect", systemImage: "shield.lefthalf.filled")
            }
        }
        .displayName("Protect Dashcam footage")
        .description("Keeps the footage around this moment.")
    }
}
