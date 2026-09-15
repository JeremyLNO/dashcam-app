import AVFoundation
import CoreLocation
import SwiftData
import UIKit
import XCTest
@testable import Dashcam

/// The two-up player, over footage written by `SegmentWriter` itself.
///
/// Every earlier test of this built its clips with a plain `AVAssetWriter` and a handful of
/// frames — and every one of them passed while the two-camera playback came out black on
/// the phone. Clips written for a test are not the clips the app writes: the real ones are
/// **fragmented** movies (`movieFragmentInterval`), they carry a timed metadata track, they
/// are started at a capture-clock timestamp in the tens of thousands of seconds, and the two
/// cameras start milliseconds apart from each other. Any of those can be the difference.
///
/// So this drives the writer the app ships, with sample buffers, and composes what lands on
/// disk.
@MainActor
final class RecordedFootageCompositionTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var sessionID: UUID!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A capture clock, which starts at boot and not at zero. The PTS the writer is handed
    /// on a phone is of this order, never `.zero`.
    private let rearClockOrigin = CMTime(value: 54_321_123_456_789, timescale: 1_000_000_000)
    /// The cabin camera's first frame does not land on the same instant as the road's.
    private let frontClockOrigin = CMTime(value: 54_321_131_987_654, timescale: 1_000_000_000)

    private let roadColour = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    private let cabinColour = UIColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)

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

    // MARK: - Driving the real writer

    private func pixelBuffer(colour: UIColor, size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer),
            kCVReturnSuccess
        )
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixels),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(colour.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return pixels
    }

    private func sample(_ pixels: CVPixelBuffer, at time: CMTime, fps: Int) throws -> CMSampleBuffer {
        var formatDescription: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &formatDescription),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing, sampleBufferOut: &buffer),
            noErr
        )
        return try XCTUnwrap(buffer)
    }

    /// Runs one camera's writer for `seconds`, exactly as the capture pipeline does: a
    /// sample buffer per frame, a position handed over twice a second, and a `stop()` that
    /// waits for the files to be closed.
    private func record(
        camera: CameraPosition, colour: UIColor, size: CGSize,
        clockOrigin: CMTime, seconds: Double, segmentDuration: TimeInterval, fps: Int = 30,
        includesAudio: Bool
    ) async throws -> [FinishedSegment] {
        let format = VideoFormatDescriptor(
            outputWidth: Int(size.width), outputHeight: Int(size.height),
            fps: fps, bitrate: 8_000_000, codec: AVVideoCodecType.h264.rawValue
        )
        let collected = Collector()
        let writer = SegmentWriter(
            camera: camera, sessionID: sessionID, format: format,
            includesAudio: includesAudio, segmentDuration: segmentDuration,
            onSegmentFinished: { segment in collected.append(segment) },
            onFailure: { error in XCTFail("writer failed: \(error.localizedDescription)") }
        )

        let pixels = try pixelBuffer(colour: colour, size: size)
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            let pts = CMTimeAdd(clockOrigin, CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            writer.appendVideo(try sample(pixels, at: pts, fps: fps))
            // Paced, because the writer's inputs are configured `expectsMediaDataInRealTime`
            // and drop whatever arrives while they are busy. Pushing a whole drive in one
            // loop produces a single mangled file — which is a fault of the harness, not of
            // the app, and would be mistaken for the defect being hunted.
            try? await Task.sleep(nanoseconds: 4_000_000)
            // The timed metadata track, which only exists on a drive that has a position —
            // i.e. on every real drive, and on none of the earlier tests.
            if frame % (fps / 2) == 0 {
                writer.appendMetadata(
                    location: CLLocation(latitude: 48.8566 + Double(frame) / 100_000, longitude: 2.3522),
                    gForce: 1.0
                )
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.stop { continuation.resume() }
        }
        return collected.all()
    }

    /// The writer calls back from its own queue.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var segments: [FinishedSegment] = []
        func append(_ segment: FinishedSegment) { lock.lock(); segments.append(segment); lock.unlock() }
        func all() -> [FinishedSegment] { lock.lock(); defer { lock.unlock() }; return segments.sorted { $0.index < $1.index } }
    }

    private func index(_ segments: [FinishedSegment]) {
        for segment in segments where segment.succeeded {
            index.insertSegment(segment, sessionID: sessionID, isProtected: false)
        }
    }

    // MARK: - Reading the pixels back

    private func renderFrame(_ built: BuiltComposition, at seconds: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    private func colour(_ image: CGImage, x: Double, y: Double, size: Double = 0.06) -> (r: Int, g: Int, b: Int) {
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

    // MARK: - The test

    /// A drive as the app records one: two cameras, several segments each, cut at
    /// boundaries computed from each camera's own first frame.
    func testTheTwoUpPlayerShowsFootageTheAppItselfWrote() async throws {
        let size = CGSize(width: 1280, height: 720)
        let rear = try await record(camera: .rear, colour: roadColour, size: size,
                                    clockOrigin: rearClockOrigin, seconds: 6, segmentDuration: 2, fps: 15,
                                    includesAudio: false)
        let front = try await record(camera: .front, colour: cabinColour, size: size,
                                     clockOrigin: frontClockOrigin, seconds: 6, segmentDuration: 2, fps: 15,
                                     includesAudio: false)
        index(rear)
        index(front)

        let session = try XCTUnwrap(index.session(id: sessionID))
        XCTAssertGreaterThanOrEqual(session.rearSegments.count, 3, "the writer produced no road segments")
        XCTAssertGreaterThanOrEqual(session.frontSegments.count, 3, "the writer produced no cabin segments")

        let built = try await SessionComposition.pictureInPicture(
            rear: session.rearSegments, front: session.frontSegments, includeAudio: false
        )
        let problems = CompositionDiagnostics.problems(
            in: try XCTUnwrap(built.videoComposition), duration: built.duration
        )
        XCTAssertEqual(problems, [], "the layout does not cover the drive: \(problems)")

        // Sampled across the whole drive, not at one instant: a composition that is right
        // for its first segment and black afterwards is the defect being looked for.
        for moment in [0.5, 2.5, 4.5] {
            let image = try renderFrame(built, at: moment)
            let road = colour(image, x: 0.35, y: 0.5)
            XCTAssertTrue(isReddish(road), "the road is missing at \(moment)s: \(road)")
            let cabin = colour(image, x: 0.86, y: 0.17)
            XCTAssertTrue(isBluish(cabin), "the cabin inset is missing at \(moment)s: \(cabin)")
        }
    }
}
