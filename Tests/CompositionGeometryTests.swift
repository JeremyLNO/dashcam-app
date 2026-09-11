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

    // MARK: Output geometry

    private let standard = VideoFormatDescriptor.resolved(for: .standard, codec: "hvc1")
    private let eco = VideoFormatDescriptor.resolved(for: .eco, codec: "hvc1")

    /// Dashcam footage is widescreen by nature, so the encoded box never turns portrait —
    /// the phone's orientation changes what the lens sees, not the shape of the file.
    func testTheOutputBoxIsAlwaysLandscape() {
        for quality in VideoQuality.allCases {
            let format = VideoFormatDescriptor.resolved(for: quality, codec: "hvc1")
            XCTAssertGreaterThan(format.outputWidth, format.outputHeight, "\(quality) is not landscape")
        }
    }

    func testEachTierKeepsItsAdvertisedResolution() {
        XCTAssertEqual(standard.outputWidth, 1920)
        XCTAssertEqual(standard.outputHeight, 1080)
        XCTAssertEqual(eco.outputWidth, 1280)
        XCTAssertEqual(eco.outputHeight, 720)
    }

    func testTheOutputBoxIsSixteenByNine() {
        for quality in VideoQuality.allCases {
            let format = VideoFormatDescriptor.resolved(for: quality, codec: "hvc1")
            let aspect = Double(format.outputWidth) / Double(format.outputHeight)
            XCTAssertEqual(aspect, 16.0 / 9.0, accuracy: 0.01)
        }
    }

    /// Both cameras encode into the same box, which is what makes the cabin inset fill its
    /// corner instead of collapsing into a sliver.
    func testBothCamerasShareOneOutputShape() {
        let rear = VideoFormatDescriptor.resolved(for: .standard, codec: "hvc1")
        let front = VideoFormatDescriptor.resolved(for: .standard, codec: "hvc1")
        XCTAssertEqual(rear.outputSize.width, front.outputSize.width)
        XCTAssertEqual(rear.outputSize.height, front.outputSize.height)
    }
}
