import AVFoundation
import XCTest
@testable import Dashcam

/// The transform maths behind picture-in-picture and the overlay pass.
///
/// These are the calculations where a mistake produces a black frame or squashed footage
/// rather than an error, so they are worth pinning down precisely.
final class CompositionGeometryTests: XCTestCase {
    private let landscape = CGSize(width: 1920, height: 1080)

    func testIdentityFootageFillsTheRenderRectExactly() {
        let target = CGRect(origin: .zero, size: landscape)
        let transform = SessionComposition.fittingTransform(naturalSize: landscape, preferred: .identity, into: target)

        let result = CGRect(origin: .zero, size: landscape).applying(transform)
        XCTAssertEqual(result.minX, 0, accuracy: 0.01)
        XCTAssertEqual(result.minY, 0, accuracy: 0.01)
        XCTAssertEqual(result.width, 1920, accuracy: 0.01)
        XCTAssertEqual(result.height, 1080, accuracy: 0.01)
    }

    /// The case that fails silently if the bounding box is not normalised back to the
    /// origin: rotated content lands outside the render rect and the export is black.
    func testRotatedFootageIsBroughtBackInsideTheRenderRect() {
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let displaySize = SessionComposition.displaySize(naturalSize: landscape, transform: rotation)
        let target = CGRect(origin: .zero, size: displaySize)

        let transform = SessionComposition.fittingTransform(naturalSize: landscape, preferred: rotation, into: target)
        let result = CGRect(origin: .zero, size: landscape).applying(transform)

        XCTAssertEqual(result.minX, 0, accuracy: 0.01)
        XCTAssertEqual(result.minY, 0, accuracy: 0.01)
        XCTAssertEqual(displaySize.width, 1080, accuracy: 0.01)
        XCTAssertEqual(displaySize.height, 1920, accuracy: 0.01)
    }

    func testAspectRatioIsPreservedWhenFittingIntoAnInset() {
        let inset = CGRect(x: 1300, y: 800, width: 537, height: 302)
        let transform = SessionComposition.fittingTransform(naturalSize: landscape, preferred: .identity, into: inset)
        let result = CGRect(origin: .zero, size: landscape).applying(transform)

        XCTAssertEqual(result.width / result.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(result.width, inset.width + 0.01)
        XCTAssertLessThanOrEqual(result.height, inset.height + 0.01)
    }

    func testFittedContentIsCentredInsideItsTarget() {
        // A 4:3 source in a 16:9 box leaves equal pillarbox bars.
        let source = CGSize(width: 1440, height: 1080)
        let target = CGRect(origin: .zero, size: landscape)
        let transform = SessionComposition.fittingTransform(naturalSize: source, preferred: .identity, into: target)
        let result = CGRect(origin: .zero, size: source).applying(transform)

        XCTAssertEqual(result.minX, target.maxX - result.maxX, accuracy: 0.01)
        XCTAssertEqual(result.midX, target.midX, accuracy: 0.01)
        XCTAssertEqual(result.midY, target.midY, accuracy: 0.01)
    }

    func testDegenerateSourceFallsBackToThePreferredTransform() {
        let transform = SessionComposition.fittingTransform(
            naturalSize: .zero, preferred: .identity, into: CGRect(origin: .zero, size: landscape)
        )
        XCTAssertEqual(transform, .identity)
    }

    func testDisplaySizeIsAlwaysEven() {
        let odd = CGSize(width: 1281, height: 721)
        let size = SessionComposition.displaySize(naturalSize: odd, transform: .identity)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
    }

    // MARK: Encoder dimensions

    private let standard = VideoFormatDescriptor.resolved(for: .standard, codec: "hvc1")
    private let eco = VideoFormatDescriptor.resolved(for: .eco, codec: "hvc1")

    func testEncodeSizeNeverUpscales() {
        let result = standard.encodeSize(forFrame: 1280, height: 720)
        XCTAssertEqual(result.width, 1280)
        XCTAssertEqual(result.height, 720)
    }

    func testEncodeSizePreservesTheCapturedAspectRatio() {
        // A 4:3 sensor format downscaled to 1080p must become 1440x1080, not 1920x1080.
        let result = standard.encodeSize(forFrame: 2880, height: 2160)
        XCTAssertEqual(result.width, 1440)
        XCTAssertEqual(result.height, 1080)
    }

    /// The property that makes tilting work: a tier means "1080 across the narrow
    /// dimension", so landscape and portrait frames cost the same and both stay sharp.
    func testTheTierAppliesToTheShortSideWhicheverWayThePhoneIsHeld() {
        let landscape = standard.encodeSize(forFrame: 3840, height: 2160)
        let portrait = standard.encodeSize(forFrame: 2160, height: 3840)

        XCTAssertEqual(landscape.width, 1920)
        XCTAssertEqual(landscape.height, 1080)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        XCTAssertEqual(landscape.width * landscape.height, portrait.width * portrait.height)
    }

    func testEcoTargetsSevenTwentyOnTheShortSide() {
        let result = eco.encodeSize(forFrame: 1920, height: 1080)
        XCTAssertEqual(result.height, 720)
        XCTAssertEqual(result.width, 1280)
    }

    func testEncodeSizeIsAlwaysEven() {
        let result = standard.encodeSize(forFrame: 1999, height: 1125)
        XCTAssertEqual(result.width % 2, 0)
        XCTAssertEqual(result.height % 2, 0)
    }

    /// Turning the phone changes the encoded shape, which is what forces the writer to
    /// cut a new segment — an `AVAssetWriterInput` cannot change dimensions once open.
    func testRotatingTheFrameChangesTheEncodedShape() {
        let landscape = standard.encodeSize(forFrame: 1920, height: 1080)
        let portrait = standard.encodeSize(forFrame: 1080, height: 1920)
        XCTAssertNotEqual(landscape.width, portrait.width)
        XCTAssertEqual(landscape.width, portrait.height)
        XCTAssertEqual(landscape.height, portrait.width)
    }

    /// A frame that is already at the target must not be resized at all — otherwise every
    /// rounding pass would nibble the picture.
    func testFramesAtTheTargetAreUntouched() {
        let result = standard.encodeSize(forFrame: 1920, height: 1080)
        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.height, 1080)
    }
}
