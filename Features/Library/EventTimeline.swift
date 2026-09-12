import SwiftUI

/// A drive at a glance: one horizontal bar, one mark per event.
///
/// This is the fastest path from "something happened on the way home" to the frame that
/// shows it. Scrubbing a two-hour recording to find a three-second incident is the single
/// most tedious thing about owning a dashcam, and a timeline removes it: the marks are
/// exactly where the protections are, and tapping one seeks the player there.
struct EventTimeline: View {
    struct Mark: Identifiable, Equatable {
        let id: UUID
        /// Seconds from the start of the drive.
        let offset: TimeInterval
        let origin: ProtectionOrigin
        let magnitude: Double
    }

    let duration: TimeInterval
    let marks: [Mark]
    /// Shaded spans showing which parts of the drive are protected.
    let protectedSpans: [ClosedRange<TimeInterval>]
    let playheadOffset: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private let trackHeight: CGFloat = 30

    var body: some View {
        // No heading of its own: the card that holds it names it, and the component was
        // printing "Timeline" directly under the card's own title.
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.surfaceElevated)

                    ForEach(Array(protectedSpans.enumerated()), id: \.offset) { _, span in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.warning.opacity(0.28))
                            .frame(width: max(3, CGFloat(span.upperBound - span.lowerBound) / scale * width))
                            .offset(x: CGFloat(span.lowerBound) / scale * width)
                    }

                    ForEach(marks) { mark in
                        Capsule()
                            .fill(colour(for: mark.origin))
                            .frame(width: 3, height: trackHeight)
                            .offset(x: min(width - 3, CGFloat(mark.offset) / scale * width))
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: trackHeight)
                        .offset(x: min(width - 2, CGFloat(playheadOffset) / scale * width))
                }
                .frame(height: trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        let fraction = min(max(0, value.location.x / width), 1)
                        onSeek(TimeInterval(fraction) * duration)
                    }
                )
            }
            .frame(height: trackHeight)

            if marks.isEmpty {
                Text(key: "timeline.no_events")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                legend
            }
        }
    }

    /// Guards against a zero-length drive turning every offset into a division by zero.
    private var scale: CGFloat { CGFloat(max(duration, 1)) }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(marks) { mark in
                    Button {
                        onSeek(mark.offset)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mark.origin.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                            Text(verbatim: Format.duration(mark.offset))
                                .font(Theme.caption)
                            if mark.magnitude > 0 {
                                Text(verbatim: String(format: "%.1f g", mark.magnitude))
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surface))
                        .foregroundStyle(colour(for: mark.origin))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(L10n.t(mark.origin.titleKey)) — \(Format.duration(mark.offset))"))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func colour(for origin: ProtectionOrigin) -> Color {
        switch origin {
        case .impact: return Theme.accent
        case .harshBraking: return Theme.warning
        case .manual, .carPlay: return Theme.positive
        }
    }
}
