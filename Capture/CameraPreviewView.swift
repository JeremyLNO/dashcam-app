import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVCaptureVideoPreviewLayer` that the capture manager owns.
///
/// The layer is created once and reused, never re-parented per SwiftUI update: a preview
/// layer that gets detached and reattached tears down its connection, which on a
/// multi-cam session means renegotiating the whole hardware budget.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        view.attach(previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.attach(previewLayer)
    }

    final class PreviewHostView: UIView {
        private weak var attached: AVCaptureVideoPreviewLayer?

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            guard attached !== layer else { return }
            attached?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.addSublayer(layer)
            attached = layer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Frame changes must not animate: an implicit CALayer animation on a preview
            // layer shows a visibly stretched frame on every rotation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attached?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// What to show where a preview would be when there is nothing to preview.
struct CameraUnavailableView: View {
    let messageKey: String
    var systemImage: String = "video.slash"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(key: messageKey)
                .font(Theme.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}
