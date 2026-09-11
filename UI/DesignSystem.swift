import SwiftUI

/// The visual language: dark, automotive, quiet.
///
/// One rule governs colour here — red means *recording* or *destructive*, and nothing
/// else. A dashboard that uses an alarm colour for decoration teaches the driver to
/// ignore it.
enum Theme {
    // MARK: Colour

    static let background = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let surface = Color(red: 0.09, green: 0.10, blue: 0.11)
    static let surfaceElevated = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let separator = Color.white.opacity(0.08)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)

    /// Reserved for the REC state and destructive actions.
    static let accent = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let positive = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.16)
    /// Crazy Bee Labs honey, used only for the brand footer.
    static let brand = Color(red: 0.98, green: 0.76, blue: 0.18)

    // MARK: Metrics

    /// Minimum tap target for anything usable from the driver's seat. Well above the
    /// 44 pt HIG floor on purpose: this gets pressed one-handed, in motion.
    static let controlHeight: CGFloat = 68
    /// Landscape equivalent. Still well clear of the 44 pt HIG minimum.
    static let compactControlHeight: CGFloat = 52
    /// Room to leave under the controls so the floating tab bar never covers them.
    static let floatingTabBarClearance: CGFloat = 46
    static let cornerRadius: CGFloat = 18
    static let tileCorner: CGFloat = 14
    static let spacing: CGFloat = 14

    // MARK: Type

    /// Monospaced digits so the running timer does not jitter as the seconds change.
    static func timer(_ size: CGFloat = 52) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    static let title = Font.system(size: 28, weight: .bold, design: .rounded)
    static let headline = Font.system(size: 19, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 16, weight: .regular)
    static let caption = Font.system(size: 13, weight: .medium)
    static let tileValue = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
}

/// Big, high-contrast, unmistakable. Used for Start/Stop and Protect.
struct DriverButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white
    var isProminent: Bool = true
    /// Landscape has far less vertical room; the target still clears the 44 pt floor.
    var height: CGFloat = Theme.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isProminent ? 0 : 0.18), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One glanceable fact: a label, a value, and an optional state colour.
struct StatusTile: View {
    let titleKey: String
    let value: String
    var systemImage: String
    var tint: Color = Theme.textSecondary
    /// Landscape trims the padding a little; the label and value still stack, because
    /// putting them on one line truncates both at the width a side panel can offer.
    var isDense: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: isDense ? 3 : 6) {
            label
            valueText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isDense ? 9 : 12)
        .padding(.vertical, isDense ? 7 : 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                .fill(Theme.surface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(L10n.t(titleKey)): \(value)"))
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(key: titleKey)
                .font(Theme.caption)
        }
        .foregroundStyle(Theme.textTertiary)
    }

    private var valueText: some View {
        Text(verbatim: value)
            .font(Theme.tileValue)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// The pulsing REC dot. Animation is suppressed when the user asked for reduced motion.
struct RecordingIndicator: View {
    let isRecording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRecording ? Theme.accent : Theme.textTertiary)
                .frame(width: 14, height: 14)
                .opacity(isRecording && isDimmed && !reduceMotion ? 0.25 : 1)
                .animation(
                    isRecording && !reduceMotion
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: isDimmed
                )
            Text(key: isRecording ? "rec.on" : "rec.off")
                .font(Theme.headline)
                .foregroundStyle(isRecording ? Theme.accent : Theme.textSecondary)
        }
        .onAppear { isDimmed = isRecording }
        .onChange(of: isRecording) { _, newValue in isDimmed = newValue }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(key: isRecording ? "a11y.recording" : "a11y.idle"))
    }
}

/// Section heading used throughout Settings and the library.
struct SectionHeader: View {
    let titleKey: String

    var body: some View {
        Text(key: titleKey)
            .font(Theme.caption)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

extension View {
    /// Standard card treatment for grouped content.
    func dashcamCard() -> some View {
        padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            )
    }
}
