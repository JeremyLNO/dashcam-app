import AVFoundation
import QuartzCore
import XCTest
@testable import Dashcam

/// The mark burned into an exported file.
///
/// Its value is narrow and worth stating: it is **not** proof — anyone can draw the same
/// words on a frame. It is the only part of the provenance that survives what happens to a
/// video after it leaves the phone, where every messaging app strips metadata and every
/// re-encode drops it.
final class OverlaySignatureTests: XCTestCase {
    private let renderSize = CGSize(width: 1920, height: 1080)

    private func signatureLayers(in parent: CALayer) -> [CATextLayer] {
        (parent.sublayers ?? []).compactMap { $0 as? CATextLayer }
            .filter { $0.name == OverlayRenderer.signatureLayerName }
    }

    /// Someone who turned every measurement off can still want the file to say where it
    /// came from — so a signature alone must be enough to build the overlay.
    func testASignatureAloneIsWorthAnOverlay() throws {
        let built = try XCTUnwrap(OverlayRenderer.makeAnimationTool(
            renderSize: renderSize, stamps: [], signature: "Dashcam Pocket 1.0.0 (21)"
        ))
        XCTAssertEqual(signatureLayers(in: built.parent).count, 1)
    }

    /// And nothing at all still means nothing: an empty overlay tool would re-encode a
    /// file to draw nothing on it.
    func testNothingToDrawBuildsNoTool() {
        XCTAssertNil(OverlayRenderer.makeAnimationTool(renderSize: renderSize, stamps: [], signature: nil))
    }

    func testTheSignatureCarriesTheAppNameAndVersion() throws {
        let built = try XCTUnwrap(OverlayRenderer.makeAnimationTool(
            renderSize: renderSize, stamps: [], signature: "Dashcam Pocket 1.0.0 (21)"
        ))
        let layer = try XCTUnwrap(signatureLayers(in: built.parent).first)
        XCTAssertEqual(layer.string as? String, "Dashcam Pocket 1.0.0 (21)")
    }

    /// It sits in the corner opposite the data bar. Two marks in the same corner would
    /// overlap, and the one that lost would be unreadable in every export.
    func testItSitsInTheCornerOppositeTheDataBar() throws {
        let stamp = OverlayStamp(start: 0, duration: 5, text: "14/09/2026 10:03:22   50 km/h")
        let built = try XCTUnwrap(OverlayRenderer.makeAnimationTool(
            renderSize: renderSize, stamps: [stamp], signature: "Dashcam Pocket"
        ))
        let signature = try XCTUnwrap(signatureLayers(in: built.parent).first)

        XCTAssertGreaterThan(signature.frame.midX, renderSize.width / 2, "the data bar owns the left")
        XCTAssertGreaterThan(signature.frame.midY, renderSize.height / 2, "it stays out of the road, near the bottom")
        XCTAssertLessThanOrEqual(signature.frame.maxX, renderSize.width, "and inside the frame")
    }

    /// Visible for the whole file, not for a slice: a mark that blinks is a mark someone
    /// can cut around.
    func testTheSignatureIsNotAnimatedAway() throws {
        let built = try XCTUnwrap(OverlayRenderer.makeAnimationTool(
            renderSize: renderSize, stamps: [], signature: "Dashcam Pocket"
        ))
        let layer = try XCTUnwrap(signatureLayers(in: built.parent).first)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertNil(layer.animation(forKey: "reveal"))
    }

    /// It scales with the frame, so a 720p export is marked as legibly as a 1080p one.
    func testTheMarkScalesWithTheFrame() {
        let small = OverlayRenderer.signatureLayer(text: "Dashcam Pocket", renderSize: CGSize(width: 1280, height: 720), fontSize: 23)
        let large = OverlayRenderer.signatureLayer(text: "Dashcam Pocket", renderSize: renderSize, fontSize: 34.5)
        XCTAssertGreaterThan(large.fontSize, small.fontSize)
    }

    /// The watermark is **never** a standing default: it alters the image, and altering
    /// the image is a decision taken for one file at export time. The app's name lives in
    /// the metadata of every recording instead, where it costs no pixel.
    func testTheWatermarkIsNotAStandingDefault() {
        XCTAssertFalse(RecordingSettings().overlayFields.contains(.signature))
    }
}
