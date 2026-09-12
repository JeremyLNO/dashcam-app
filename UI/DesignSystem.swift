import SwiftUI

/// The visual language: bright, warm, and sorted by colour.
///
/// Two rules govern it.
///
/// **Colour carries meaning, never decoration.** Each family owns a domain — coral is
/// recording and protection, blue is export and navigation, teal is location and storage,
/// orange is time, violet is quality, green is a granted state, red is destruction. A
/// screen that paints with every colour at once teaches the driver to read none of them.
///
/// **Weight carries hierarchy.** Titles are large and heavy, values are bold, everything
/// else recedes. Borders are avoided: a white surface on the cream ground, with a shadow
/// barely darker than the paper, separates better than a line does.
enum Theme {
    // MARK: Colour

    static let background = Color(hex: 0xFFF9EE)
    static let surface = Color.white
    /// Kept for the places that need a second, quieter surface on top of a card.
    static let surfaceElevated = Color(hex: 0xF6F2E9)
    static let separator = Color(hex: 0xE9E7E1)

    static let textPrimary = Color(hex: 0x08264A)
    static let textSecondary = Color(hex: 0x707681)
    static let textTertiary = Color(hex: 0x9AA0AA)

    /// Recording, protection, and the primary call to action.
    static let coral = Color(hex: 0xEF4E63)
    static let coralSoft = Color(hex: 0xFFE2E6)
    /// Export, playback, anything informational.
    static let blue = Color(hex: 0x477FF2)
    static let blueSoft = Color(hex: 0xDFEAFF)
    /// Location and storage.
    static let teal = Color(hex: 0x22A5A4)
    static let mintSoft = Color(hex: 0xDDF5EC)
    /// Time, and warnings that are not yet dangers.
    static let orange = Color(hex: 0xFF922E)
    static let orangeSoft = Color(hex: 0xFFE8CE)
    /// Quality and video settings.
    static let violet = Color(hex: 0x8658E8)
    static let violetSoft = Color(hex: 0xECE3FF)

    static let success = Color(hex: 0x18B978)
    static let danger = Color(hex: 0xE94455)

    /// Historic names, kept so the whole app did not have to be renamed in one pass.
    static let accent = coral
    static let positive = success
    static let warning = orange
    /// Crazy Bee Labs honey, used only for the brand footer.
    static let brand = Color(hex: 0xE8A317)

    // MARK: Metrics

    /// The primary call to action. Deliberately far above the 44 pt HIG floor: this gets
    /// pressed one-handed, in a moving car, without looking.
    static let controlHeight: CGFloat = 82
    /// Landscape equivalent — still well clear of the floor.
    static let compactControlHeight: CGFloat = 58
    /// Room to leave under the controls so the floating tab bar never covers them.
    static let floatingTabBarClearance: CGFloat = 46

    static let cardCorner: CGFloat = 24
    static let tileCorner: CGFloat = 18
    static let buttonCorner: CGFloat = 26
    /// Historic name for the card radius.
    static let cornerRadius: CGFloat = cardCorner
    static let spacing: CGFloat = 16

    // MARK: Type

    /// Monospaced digits so a running timer does not jitter as the seconds change.
    static func timer(_ size: CGFloat = 44) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    /// Screen titles: "Drives", "Settings".
    static let pageTitle = Font.system(size: 36, weight: .heavy)
    /// Onboarding and paywall headlines.
    static let display = Font.system(size: 40, weight: .heavy)
    static let sectionTitle = Font.system(size: 25, weight: .bold)
    static let cardTitle = Font.system(size: 18, weight: .bold)
    static let value = Font.system(size: 22, weight: .bold)
    static let body = Font.system(size: 16, weight: .regular)
    static let caption = Font.system(size: 14, weight: .regular)
    /// Historic names.
    static let title = sectionTitle
    static let headline = cardTitle
    static let tileValue = Font.system(size: 20, weight: .bold).monospacedDigit()
}

extension Color {
    /// `Color(hex: 0xEF4E63)` — the palette is specified in hex, so it is written in hex.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A colour family: a strong tone for the ink, a pale one for the ground.
struct Accent {
    let strong: Color
    let soft: Color

    static let coral = Accent(strong: Theme.coral, soft: Theme.coralSoft)
    static let blue = Accent(strong: Theme.blue, soft: Theme.blueSoft)
    static let teal = Accent(strong: Theme.teal, soft: Theme.mintSoft)
    static let orange = Accent(strong: Theme.orange, soft: Theme.orangeSoft)
    static let violet = Accent(strong: Theme.violet, soft: Theme.violetSoft)
    static let green = Accent(strong: Theme.success, soft: Theme.mintSoft)
}

// MARK: - Surfaces

extension View {
    /// A white card on the cream ground. The shadow is almost invisible on purpose: it
    /// has to lift the card without drawing a line around it.
    func dashcamCard(padding: CGFloat = 18, corner: CGFloat = Theme.cardCorner) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.surface)
            )
            .softShadow()
    }

    func softShadow() -> some View {
        shadow(color: Color(hex: 0x08264A).opacity(0.06), radius: 14, x: 0, y: 6)
    }

    /// A pale block of colour — no shadow, because it is a ground, not a card.
    func pastelCard(_ accent: Accent, padding: CGFloat = 16, corner: CGFloat = Theme.tileCorner) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(accent.soft)
            )
    }
}

// MARK: - Buttons

/// The primary call to action: full width, filled, unmistakable.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.coral
    var foreground: Color = .white
    var height: CGFloat = Theme.controlHeight
    var corner: CGFloat = Theme.buttonCorner

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A secondary action: pale ground, coloured text. Used for everything that is not the
/// one thing the screen is for — including Delete, which must never look like Export.
struct SoftButtonStyle: ButtonStyle {
    var fill: Color = Theme.blueSoft
    var foreground: Color = Theme.blue
    var height: CGFloat = 56
    var corner: CGFloat = Theme.tileCorner
    var font: Font = .system(size: 17, weight: .bold)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Historic name, still used by the driver-facing controls. Now maps onto the two styles
/// above: prominent means filled, otherwise pale.
struct DriverButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white
    var isProminent: Bool = true
    var height: CGFloat = Theme.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonStyle(fill: fill, foreground: foreground, height: height)
            .makeBody(configuration: configuration)
    }
}

// MARK: - Building blocks

/// An icon in a coloured disc. The app's most repeated shape: it is what makes a row
/// recognisable before a single word has been read.
struct IconBadge: View {
    let systemImage: String
    var accent: Accent = .blue
    /// `true` paints the disc in the strong colour and the glyph white; `false` does the
    /// reverse, for the quieter places.
    var isFilled: Bool = true
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(isFilled ? accent.strong : accent.soft)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(isFilled ? Color.white : accent.strong)
        }
        .frame(width: size, height: size)
    }
}

/// One glanceable fact on a pale ground: icon, label, value.
struct StatCard: View {
    let titleKey: String
    let value: String
    var systemImage: String
    var accent: Accent = .blue
    /// A second line under the value, for the one fact that qualifies it — how long the
    /// free space is actually worth, say. Left out everywhere it would only be noise.
    var footnote: String?
    /// Landscape trims the padding; the label and value still stack, because putting them
    /// on one line truncates both at the width a side panel can offer.
    var isDense: Bool = false

    var body: some View {
        HStack(spacing: isDense ? 8 : 12) {
            IconBadge(systemImage: systemImage, accent: accent, size: isDense ? 30 : 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(key: titleKey)
                    .font(.system(size: isDense ? 12 : 14, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(.system(size: isDense ? 15 : 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let footnote, !isDense {
                    Text(verbatim: footnote)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .pastelCard(accent, padding: isDense ? 8 : 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(L10n.t(titleKey)): \(value)"))
    }
}

/// Historic name. Same job as `StatCard`, kept so the driver screen and the discreet
/// screen did not have to change shape at the same time as everything else.
struct StatusTile: View {
    let titleKey: String
    let value: String
    var systemImage: String
    var tint: Color = Theme.blue
    var isDense: Bool = false

    var body: some View {
        StatCard(
            titleKey: titleKey,
            value: value,
            systemImage: systemImage,
            accent: Accent(strong: tint, soft: tint.opacity(0.12)),
            isDense: isDense
        )
    }
}

/// A rounded label: "Protected", "Hard Brake", "Ready".
struct Pill: View {
    let text: String
    var accent: Accent = .green
    var systemImage: String?
    var font: Font = .system(size: 13, weight: .bold)

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
            }
            Text(verbatim: text)
                .font(font)
                .lineLimit(1)
        }
        .foregroundStyle(accent.strong)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(accent.soft))
    }
}

/// A small dot followed by a word: the state of one piece of hardware.
struct StateDot: View {
    let textKey: String
    var color: Color = Theme.success

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(key: textKey)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
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
                .fill(isRecording ? Theme.coral : Theme.textTertiary)
                .frame(width: 12, height: 12)
                .opacity(isRecording && isDimmed && !reduceMotion ? 0.25 : 1)
                .animation(
                    isRecording && !reduceMotion
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: isDimmed
                )
            Text(key: isRecording ? "rec.on" : "rec.off")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isRecording ? Theme.coral : Theme.textSecondary)
        }
        .onAppear { isDimmed = isRecording }
        .onChange(of: isRecording) { _, newValue in isDimmed = newValue }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(key: isRecording ? "a11y.recording" : "a11y.idle"))
    }
}

/// A screen's title block: a large name and a quiet line under it.
struct PageHeader<Trailing: View>: View {
    let titleKey: String
    var subtitleKey: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key: titleKey)
                    .font(Theme.pageTitle)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitleKey {
                    Text(key: subtitleKey)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(titleKey: String, subtitleKey: String? = nil) {
        self.init(titleKey: titleKey, subtitleKey: subtitleKey) { EmptyView() }
    }
}

/// Section heading used inside cards and lists.
struct SectionHeader: View {
    let titleKey: String

    var body: some View {
        Text(key: titleKey)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
