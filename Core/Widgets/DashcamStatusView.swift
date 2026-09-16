import SwiftUI
import WidgetKit

/// The widget's face. Compiled into the app as well as the extension, so it can be
/// rendered and looked at by a test — a widget nobody has ever seen is a widget nobody
/// has checked.
///
/// One question, three lines: **is my dashcam in working order, and is anything waiting
/// for me?** It is not a place to browse figures; nobody reads dashcam statistics from a
/// home screen. Its whole value lives in the case where the answer is no — the drive that
/// recorded zero clips, the week with no drive at all, the protected moment still sitting
/// there unexported.
struct DashcamStatusView: View {
    let snapshot: DashcamSnapshot
    var family: WidgetFamily = .systemMedium
    var now: Date = Date()

    private var isStale: Bool {
        DashcamStatusRules.isStale(lastDriveEndedAt: snapshot.lastDriveEndedAt, now: now)
    }

    var body: some View {
        switch family {
        case .accessoryRectangular: lockScreen
        case .systemSmall: small
        default: medium
        }
    }

    // MARK: - Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            lastDrive
            Spacer(minLength: 0)
            if let protectedShort = snapshot.protectedShort {
                protectedRow(protectedShort)
            } else {
                autonomyRow
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            lastDrive
            Spacer(minLength: 0)
            autonomyRow
            if let protectedWaiting = snapshot.protectedWaiting {
                protectedRow(protectedWaiting)
            }
        }
    }

    /// The home screen already labels the widget with the app's name, so this line says
    /// what the figure below it *is* instead of repeating it.
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: isStale ? "exclamationmark.triangle.fill" : "video.fill")
                .font(.system(size: 11, weight: .bold))
            Text(verbatim: snapshot.headline)
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isStale ? Color.orange : Color.secondary)
    }

    /// The line the widget exists for. A date rendered *relative* rather than written into
    /// the snapshot, so « 6 days ago » keeps counting even if the app is never opened
    /// again — which is precisely the situation this line is meant to catch.
    private var lastDrive: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let endedAt = snapshot.lastDriveEndedAt {
                // The one value not pre-formatted by the app, and deliberately so: this is
                // the line whose whole job is to stay true while the app is *not* running,
                // which is exactly the case it exists to catch. iOS keeps it counting.
                // ⚠️ It follows the phone's language rather than the app's — the only place
                // the two can disagree, and the trade is worth it here.
                Text(endedAt, format: .relative(presentation: .named))
                    .font(.system(size: family == .systemSmall ? 17 : 20, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: snapshot.lastDriveSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(verbatim: snapshot.lastDriveSummary)
                    .font(.system(size: family == .systemSmall ? 16 : 19, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(isStale ? Color.orange : Color.primary)
    }

    private var autonomyRow: some View {
        row(icon: "internaldrive.fill", text: snapshot.autonomy, tint: .secondary)
    }

    private func protectedRow(_ text: String) -> some View {
        row(icon: "shield.lefthalf.filled", text: text, tint: .blue)
    }

    private func row(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(verbatim: text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Lock screen

    /// Where a phone in a windscreen cradle actually spends its time.
    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: isStale ? "exclamationmark.triangle.fill" : "video.fill")
                    .font(.system(size: 11, weight: .bold))
                if let endedAt = snapshot.lastDriveEndedAt {
                    Text(endedAt, format: .relative(presentation: .named))
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Text(verbatim: snapshot.lastDriveSummary).font(.system(size: 14, weight: .bold))
                }
            }
            .lineLimit(1)
            Text(verbatim: snapshot.protectedShort ?? snapshot.autonomy)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
