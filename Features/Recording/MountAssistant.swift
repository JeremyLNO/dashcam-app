import CoreMotion
import SwiftUI

/// Helps aim the phone before the drive, not after the accident.
///
/// A dashcam that films the bonnet or the sky is discovered to be useless at exactly the
/// moment it was needed. Nothing in the app could tell the driver that, because a live
/// preview looks fine to someone who is already looking at it — the eye corrects the tilt
/// the sensor records.
///
/// So the phone's own attitude is read and judged: roll says whether the horizon will
/// come out level, pitch says whether the lens is pointing at the road rather than over
/// it. Both are shown as numbers *and* as a line laid over the preview, because a driver
/// adjusts a cradle by looking, not by reading degrees.
struct MountAssistant: View {
    @EnvironmentObject private var capture: CaptureManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var attitude = AttitudeReader()

    /// Beyond this the footage is visibly crooked. Five degrees is about the point where
    /// a horizon stops looking accidental and starts looking wrong.
    private let levelTolerance: Double = 5
    /// A cradle pointing this far off the horizontal loses either the road or the sky.
    private let aimTolerance: Double = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(key: "mount.body")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                preview

                HStack(spacing: 10) {
                    reading(
                        titleKey: "mount.level",
                        value: String(format: "%.0f°", abs(attitude.rollDegrees)),
                        isGood: isLevel,
                        accent: .blue
                    )
                    reading(
                        titleKey: "mount.aim",
                        value: String(format: "%.0f°", attitude.pitchDegrees),
                        isGood: isAimed,
                        accent: .teal
                    )
                }

                verdict

                VStack(alignment: .leading, spacing: 10) {
                    tip(number: "1", key: "mount.tip.height")
                    tip(number: "2", key: "mount.tip.wipers")
                    tip(number: "3", key: "mount.tip.cabin")
                }
                .dashcamCard()
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationTitle(Text(key: "mount.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { attitude.start() }
        .onDisappear { attitude.stop() }
    }

    // MARK: - Pieces

    private var preview: some View {
        ZStack {
            Group {
                if capture.status.mode == .unavailable {
                    CameraUnavailableView(messageKey: capture.status.unavailability?.messageKey ?? "capture.error.no_camera")
                } else {
                    CameraPreviewView(previewLayer: capture.rearPreviewLayer)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous))

            // The guide sits still while the picture behind it tilts, which is what makes
            // the error visible without reading a number.
            GeometryReader { proxy in
                let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Path { path in
                    path.move(to: CGPoint(x: 12, y: centre.y))
                    path.addLine(to: CGPoint(x: proxy.size.width - 12, y: centre.y))
                }
                .stroke(isLevel ? Theme.success : Theme.coral, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))

                Path { path in
                    path.move(to: CGPoint(x: 12, y: centre.y))
                    path.addLine(to: CGPoint(x: proxy.size.width - 12, y: centre.y))
                }
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .rotationEffect(.degrees(attitude.rollDegrees), anchor: .center)
            }
            .frame(height: 220)
            .allowsHitTesting(false)
        }
        .softShadow()
    }

    private func reading(titleKey: String, value: String, isGood: Bool, accent: Accent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(
                systemImage: isGood ? "checkmark" : "exclamationmark",
                accent: isGood ? .green : .coral,
                size: 36
            )
            Text(key: titleKey)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(verbatim: value)
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(accent, padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var verdict: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemImage: isLevel && isAimed ? "checkmark.seal.fill" : "wrench.adjustable.fill",
                accent: isLevel && isAimed ? .green : .orange,
                size: 44
            )
            Text(key: verdictKey)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .pastelCard(isLevel && isAimed ? .green : .orange, padding: 14)
    }

    private func tip(number: String, key: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: number)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.textPrimary))
            Text(key: key)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var isLevel: Bool { abs(attitude.rollDegrees) <= levelTolerance }
    private var isAimed: Bool { abs(attitude.pitchDegrees) <= aimTolerance }

    private var verdictKey: String {
        if !attitude.isAvailable { return "mount.verdict.unavailable" }
        if isLevel && isAimed { return "mount.verdict.good" }
        if !isLevel { return "mount.verdict.tilted" }
        return "mount.verdict.aim"
    }
}

/// Reads the phone's attitude, and nothing else.
///
/// Deliberately separate from `MotionManager`, which watches for impacts during a drive:
/// this one runs only while the assistant is on screen, at a lazy ten samples a second,
/// and stops the moment it is dismissed.
@MainActor
final class AttitudeReader: ObservableObject {
    /// Rotation around the axis pointing out of the lens — how crooked the horizon is.
    @Published private(set) var rollDegrees: Double = 0
    /// How far the lens points above or below the horizontal.
    @Published private(set) var pitchDegrees: Double = 0
    @Published private(set) var isAvailable = true

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // The phone is held upright in a cradle, so the roll that matters for the
            // horizon is the device's own roll, and the pitch is measured from vertical.
            rollDegrees = data.attitude.roll * 180 / .pi
            pitchDegrees = (data.attitude.pitch * 180 / .pi) - 90
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    deinit {
        motion.stopDeviceMotionUpdates()
    }
}
