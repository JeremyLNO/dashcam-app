import SwiftUI
import WidgetKit

/// The home-screen and lock-screen widget.
///
/// It carries one real button — **Start** — because since iOS 17 a widget can run an
/// `AppIntent` on tap, and starting a drive is the single thing a home screen can usefully
/// do about a dashcam. It opens the app, which is not a shortcut taken lightly: iOS
/// suspends camera capture the moment an app leaves the foreground, so a button that
/// claimed to record without opening anything would advertise something the system forbids.
///
/// And by the same rule there is deliberately **no « Recording » state**, tempting as the
/// design is: a drive requires the app on screen, so at the instant a home screen becomes
/// visible the recording has already stopped. Stop and Protect on a widget would be two
/// buttons nobody could ever be in a position to press.
struct DashcamStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "company.lno.dashcam.widget.status", provider: StatusProvider()) { entry in
            DashcamStatusView(snapshot: entry.snapshot, family: entry.family, now: entry.date)
                // Dark on purpose, and the one place the widget parts company with the app:
                // a home screen is read at arm's length against a wallpaper, where the
                // app's cream ground disappears.
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName("Dashcam status")
        .description("The last drive, the recording time left, and any protected moment still waiting.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: DashcamSnapshot
    let family: WidgetFamily
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: .empty, family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(
            date: Date(),
            snapshot: DashcamSnapshotStore.read() ?? .empty,
            family: context.family
        ))
    }

    /// Several entries rather than one, spread over the next few days.
    ///
    /// The app reloads this timeline the moment anything changes — a drive ending, a clip
    /// protected — so the figures are never waiting on a schedule. What the schedule is for
    /// is the opposite case: **a phone whose owner has stopped driving.** The app is not
    /// running to tell the widget that, so the widget has to notice on its own, which it
    /// does by being asked again tomorrow with the same snapshot and a later `date`.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snapshot = DashcamSnapshotStore.read() ?? .empty
        let now = Date()
        let entries = stride(from: 0, through: 48, by: 6).map { hours in
            StatusEntry(
                date: now.addingTimeInterval(TimeInterval(hours) * 3600),
                snapshot: snapshot,
                family: context.family
            )
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}
