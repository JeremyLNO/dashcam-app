import SwiftUI
import WidgetKit

/// The home-screen and lock-screen widget.
///
/// It offers no button: starting a drive already lives in Control Center, on the Lock
/// Screen and on the Action button, all of which are reachable with the phone locked where
/// a widget is not. Duplicating it here would be a second, worse way to do the same thing.
///
/// And there is deliberately **no live « recording now » widget**, tempting as it is: a
/// drive requires the app on screen — iOS suspends camera capture otherwise — so by the
/// time a Lock Screen or Dynamic Island is visible, the recording has already stopped.
/// The one widget that could show a running drive is the one that could never be seen.
struct DashcamStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "company.lno.dashcam.widget.status", provider: StatusProvider()) { entry in
            DashcamStatusView(snapshot: entry.snapshot, family: entry.family, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Dashcam status")
        .description("The last drive, the recording time left, and any protected moment still waiting.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
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
