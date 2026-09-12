import SwiftUI
import WatchKit

struct WatchRemoteView: View {
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                status

                if link.isReachable {
                    Button {
                        WKInterfaceDevice.current().play(.success)
                        link.send(.protect)
                    } label: {
                        Label("Protect", systemImage: "shield.lefthalf.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.pink)
                    .disabled(!link.state.isRecording)

                    Button {
                        WKInterfaceDevice.current().play(.click)
                        link.send(link.state.isRecording ? .stop : .start)
                    } label: {
                        Label(
                            link.state.isRecording ? "Stop" : "Record",
                            systemImage: link.state.isRecording ? "stop.fill" : "record.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .tint(link.state.isRecording ? .gray : .red)
                } else {
                    // Not a failure to hide: the phone app has to be open for any of this
                    // to mean anything, and saying so is more useful than a dead button.
                    Text("Open Dashcam Pocket on your iPhone")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Dashcam")
        .onAppear { link.refresh() }
    }

    private var status: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(link.state.isRecording ? .red : .secondary)
                    .frame(width: 9, height: 9)
                Text(link.state.isRecording ? "Recording" : "Stopped")
                    .font(.headline)
            }
            if link.state.isRecording {
                Text(link.state.elapsedText)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
            }
            if link.state.protectedCount > 0 {
                Text("\(link.state.protectedCount) protected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
