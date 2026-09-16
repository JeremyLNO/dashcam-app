import SwiftUI
import WidgetKit

/// The widget's face. Compiled into the app as well as the extension, so it can be
/// rendered and looked at by a test — a widget nobody has ever seen is a widget nobody has
/// checked.
///
/// One question, answered at a glance: **is my dashcam in working order, and is anything
/// waiting for me?** It is not a place to browse figures; nobody reads dashcam statistics
/// from a home screen. Its whole value lives in the case where the answer is no — the drive
/// that recorded zero clips, the week with no drive at all, the protected moment still
/// sitting there unexported.
///
/// ⚠️ **There is no « Recording » state here, and there cannot be one.** A drive requires
/// the app on screen — iOS suspends camera capture otherwise — so at the instant a home
/// screen becomes visible, the recording has already stopped. A widget showing a live drive
/// is a widget nobody could ever be looking at. What takes its place is the thing that
/// *can* be done from a home screen: starting one.
struct DashcamStatusView: View {
    let snapshot: DashcamSnapshot
    var family: WidgetFamily = .systemMedium
    var now: Date = Date()
    /// Injected so a test can render the stills without an app group container.
    var stillLoader: (String?) -> Image? = { name in
        guard let url = DashcamSnapshotStore.still(named: name),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
    }

    private var isStale: Bool {
        DashcamStatusRules.isStale(lastDriveEndedAt: snapshot.lastDriveEndedAt, now: now)
    }

    private var accent: Color { isStale ? WidgetPalette.warning : WidgetPalette.accent }

    var body: some View {
        switch family {
        case .accessoryRectangular: lockScreen
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    // MARK: - Small — one gesture, made large

    /// The record button, and almost nothing else. A small widget that tries to carry
    /// figures carries them at a size nobody reads while walking to the car.
    private var small: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(WidgetPalette.secondary)
                Spacer()
                Circle().fill(accent).frame(width: 8, height: 8)
            }
            Spacer(minLength: 0)
            startButton(diameter: 74)
            Spacer(minLength: 0)
            Group {
                if let endedAt = snapshot.lastDriveEndedAt {
                    Text(endedAt, format: .relative(presentation: .named))
                } else {
                    Text(verbatim: snapshot.lastDriveClips)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isStale ? accent : WidgetPalette.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Medium — the gesture, and what it will cost

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "Dashcam Pocket")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(WidgetPalette.primary)
                Spacer()
                statePill
            }
            HStack(spacing: 10) {
                startButton(diameter: 52)
                lastDriveBlock
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            storageBar
        }
    }

    // MARK: - Large — a frame of the driver's own road

    private var large: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                still(snapshot.lastDriveStill, height: 118)
                VStack(alignment: .leading, spacing: 2) {
                    statePill
                    Text(verbatim: snapshot.lastDriveClips)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                startButton(diameter: 52)
                lastDriveBlock
                Spacer(minLength: 0)
            }

            if !snapshot.protectedStills.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: snapshot.protectedWaiting ?? "")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        ForEach(snapshot.protectedStills.prefix(3), id: \.self) { name in
                            still(name, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            storageBar
        }
    }

    // MARK: - Pieces

    /// The one thing a home screen can actually do about a dashcam.
    ///
    /// A real button, not a link: since iOS 17 a widget runs an `AppIntent` on tap. It
    /// still opens the app, and that is not a shortcut taken lightly — a control that
    /// claimed to record without opening anything would be advertising something iOS does
    /// not allow.
    private func startButton(diameter: CGFloat) -> some View {
        Button(intent: ControlStartRecordingIntent()) {
            ZStack {
                Circle().fill(WidgetPalette.accent.opacity(0.18))
                Circle().strokeBorder(WidgetPalette.accent.opacity(0.55), lineWidth: 2)
                Circle().fill(WidgetPalette.accent).padding(diameter * 0.22)
            }
            .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
    }

    private var statePill: some View {
        HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text(verbatim: isStale ? snapshot.stateStale : snapshot.state)
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(accent.opacity(0.85)))
    }

    private var lastDriveBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let endedAt = snapshot.lastDriveEndedAt {
                // The one value not pre-formatted by the app, and deliberately so: this is
                // the line whose whole job is to stay true while the app is *not* running,
                // which is exactly the case it exists to catch. iOS keeps it counting.
                Text(endedAt, format: .relative(presentation: .named))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                Text(verbatim: snapshot.lastDriveDuration)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(WidgetPalette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: snapshot.lastDriveClips)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(verbatim: snapshot.lastDriveClips)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    /// Free space, the share already used, and what that is worth in hours — which is the
    /// only one of the three a driver can act on.
    private var storageBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive.fill").font(.system(size: 11, weight: .semibold))
                Text(verbatim: snapshot.storageFree)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(Int((snapshot.storageUsedFraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(WidgetPalette.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetPalette.track)
                    Capsule()
                        .fill(WidgetPalette.bar)
                        .frame(width: max(3, proxy.size.width * min(1, max(0, snapshot.storageUsedFraction))))
                }
            }
            .frame(height: 6)

            if family != .systemMedium {
                Text(verbatim: snapshot.autonomy)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// A real frame of the drive, or the gradient that stands in for one. Never an empty
    /// box: a widget whose picture failed to load must still look like a design.
    private func still(_ name: String?, height: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [WidgetPalette.stillTop, WidgetPalette.stillBottom],
                startPoint: .top, endPoint: .bottom
            )
            if let image = stillLoader(name) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.05)],
                    startPoint: .bottom, endPoint: .center
                )
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - Lock screen

    /// Where a phone in a windscreen cradle actually spends its time. Monochrome by system
    /// decree, so everything here is shape and weight rather than colour.
    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: isStale ? "exclamationmark.triangle.fill" : "video.fill")
                    .font(.system(size: 11, weight: .bold))
                if let endedAt = snapshot.lastDriveEndedAt {
                    Text(endedAt, format: .relative(presentation: .named))
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Text(verbatim: snapshot.lastDriveClips).font(.system(size: 14, weight: .bold))
                }
            }
            .lineLimit(1)
            Text(verbatim: snapshot.protectedShort ?? snapshot.storageFree)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
