import AVFoundation
import CoreGraphics
import SwiftData
import UIKit
import XCTest
@testable import Dashcam

/// Renders the two-up composition and looks at the pixels.
///
/// Every earlier test of this code checked geometry maths — transforms, rects, render
/// sizes — and all of them passed while the cabin camera was invisible in the player.
/// Arithmetic about where a layer *should* land is not evidence that it landed there.
/// These tests build a composition from two differently coloured clips, render a frame,
/// and sample it.
@MainActor
final class PictureInPictureRenderTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var sessionID: UUID!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private let roadColour = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)   // red
    private let cabinColour = UIColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)  // blue

    override func setUp() async throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: start, quality: .standard)
    }

    override func tearDown() async throws {
        TestSupport.removeSessionFiles(sessionID)
    }

    /// Writes one real clip per camera at the given size.
    private func stage(rear: CGSize, front: CGSize) async throws {
        for (camera, size, colour) in [
            (CameraPosition.rear, rear, roadColour),
            (CameraPosition.front, front, cabinColour),
        ] {
            let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: 0)
            let url = StorageLocations.prepareURL(forRelativePath: relativePath)
            let written = await DemoDataSeeder.writeSolidColourMovie(
                to: url, colour: colour, size: size, seconds: 2
            )
            XCTAssertTrue(written, "could not stage the \(camera.rawValue) clip")

            index.insertSegment(FinishedSegment(
                camera: camera, index: 0,
                startDate: start, endDate: start.addingTimeInterval(2),
                relativePath: relativePath,
                fileSize: StorageManager.fileSize(at: url),
                width: Int(size.width), height: Int(size.height), fps: 30,
                codec: AVVideoCodecType.h264.rawValue, succeeded: true
            ), sessionID: sessionID, isProtected: false)
        }
    }

    private func renderFrame(_ built: BuiltComposition) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        // Both tolerances at zero: with a tolerance the generator is free to hand back a
        // neighbouring frame, and a sample of the wrong frame is a verdict about nothing.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
    }

    /// Average colour of a rectangle expressed in fractions of the image.
    private func sample(_ image: CGImage, x: Double, y: Double, size: Double = 0.06) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x0 = Int(Double(width) * (x - size / 2)), x1 = Int(Double(width) * (x + size / 2))
        let y0 = Int(Double(height) * (y - size / 2)), y1 = Int(Double(height) * (y + size / 2))
        var totals = (0, 0, 0), count = 0
        for py in max(0, y0)..<min(height, y1) {
            for px in max(0, x0)..<min(width, x1) {
                let offset = (py * width + px) * 4
                totals.0 += Int(pixels[offset]); totals.1 += Int(pixels[offset + 1]); totals.2 += Int(pixels[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (totals.0 / count, totals.1 / count, totals.2 / count)
    }

    private func isReddish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 120 && c.r > c.b + 40 }
    private func isBluish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.b > 100 && c.b > c.r + 40 }

    // MARK: Tests

    /// The failure the user reported: only one camera visible in the player.
    func testBothCamerasAppearInThePictureInPictureFrame() async throws {
        try await stage(rear: CGSize(width: 1280, height: 720), front: CGSize(width: 1280, height: 720))
        let session = try XCTUnwrap(index.session(id: sessionID))

        let built = try await SessionComposition.pictureInPicture(
            rear: session.rearSegments, front: session.frontSegments, includeAudio: false
        )
        let image = try renderFrame(built)

        let centre = sample(image, x: 0.35, y: 0.5)
        XCTAssertTrue(isReddish(centre), "the road camera is not filling the frame: \(centre)")

        // Top-right, where the live recording screen also puts it.
        let inset = sample(image, x: 0.86, y: 0.17)
        XCTAssertTrue(isBluish(inset), "the cabin camera is missing from the inset: \(inset)")

        // And nowhere else: the other three corners are road.
        for (label, x, y) in [("top-left", 0.14, 0.17), ("bottom-left", 0.14, 0.83),
                              ("bottom-right", 0.86, 0.83)] {
            let corner = sample(image, x: x, y: y)
            XCTAssertTrue(isReddish(corner), "\(label) should be road, got \(corner)")
        }
    }

    /// Even if the two cameras disagree about shape, the inset must still be visible —
    /// fitted, not collapsed into a sliver.
    func testTheCabinInsetSurvivesAShapeMismatch() async throws {
        try await stage(rear: CGSize(width: 1280, height: 720), front: CGSize(width: 720, height: 1280))
        let session = try XCTUnwrap(index.session(id: sessionID))

        let built = try await SessionComposition.pictureInPicture(
            rear: session.rearSegments, front: session.frontSegments, includeAudio: false
        )
        let image = try renderFrame(built)

        XCTAssertTrue(isReddish(sample(image, x: 0.35, y: 0.5)), "road missing")
        XCTAssertTrue(isBluish(sample(image, x: 0.86, y: 0.17, size: 0.04)), "cabin missing")
    }

    /// The single-camera path has to render too — it is what the Road and Cabin tabs use.
    func testTheSingleCameraLayoutFillsTheFrame() async throws {
        try await stage(rear: CGSize(width: 1280, height: 720), front: CGSize(width: 1280, height: 720))
        let session = try XCTUnwrap(index.session(id: sessionID))

        let built = try await SessionComposition.singleWithLayout(
            segments: session.frontSegments, includeAudio: false
        )
        let image = try renderFrame(built)

        XCTAssertTrue(isBluish(sample(image, x: 0.5, y: 0.5)), "the cabin track did not render")
    }
}
