import SwiftUI

/// The near-black screen.
///
/// It is *not* a background mode — iOS does not allow camera capture from a suspended
/// app, and this app does not pretend otherwise. The app stays in the foreground and the
/// session keeps running; only the preview layers are removed from the hierarchy, which
/// is a rendering change and has no effect whatsoever on capture.
///
/// What it buys the driver: no bright rectangle reflecting in the windscreen at night,
/// and far less power spent on the display.
struct DiscreetScreen: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    let status: CaptureStatus
    let freeSpace: Int64
    let onProtect: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                HStack(spacing: 10) {
                    Circle()
                        .fill(isRecording ? Theme.accent : Theme.textTertiary)
                        .frame(width: 12, height: 12)
                    Text(key: isRecording ? "rec.on" : "rec.off")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(isRecording ? Theme.accent.opacity(0.9) : Theme.textTertiary)
                }

                Text(verbatim: Format.duration(elapsed))
                    .font(Theme.timer(56))
                    .foregroundStyle(Color.white.opacity(0.82))

                HStack(spacing: 18) {
                    cameraChip(key: "camera.rear", active: status.rearActive)
                    cameraChip(key: "camera.front", active: status.frontActive)
                }

                Text(verbatim: Format.bytes(freeSpace))
                    .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)

                Spacer()

                Button(action: onProtect) {
                    Label(
                        title: { Text(key: "action.protect") },
                        icon: { Image(systemName: "shield.lefthalf.filled") }
                    )
                }
                .buttonStyle(DriverButtonStyle(fill: Color.white.opacity(0.10), foreground: .white.opacity(0.9), isProminent: false))
                .disabled(!isRecording)
                .padding(.horizontal, 32)

                Text(key: "discreet.tap_to_exit")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
                    .padding(.bottom, 18)
            }
        }
        // The whole surface exits, except the Protect button which handles its own tap.
        .contentShape(Rectangle())
        .onTapGesture(perform: onExit)
        .accessibilityAction(named: Text(key: "discreet.exit"), onExit)
    }

    private func cameraChip(key: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Theme.positive.opacity(0.8) : Theme.textTertiary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(key: key)
                .font(Theme.caption)
                .foregroundStyle(active ? Theme.textSecondary : Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(L10n.t(key)): \(L10n.t(active ? "status.on" : "status.off"))"))
    }
}
