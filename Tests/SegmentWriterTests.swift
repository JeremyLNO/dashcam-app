import AVFoundation
import CoreVideo
import UIKit
import XCTest
@testable import Dashcam

/// Drives a real `SegmentWriter` with synthetic frames.
///
/// These exist because the whole suite was green while the app could not write a single
/// file on a device. Every other test reached the disk through a helper that created the
/// session folder first — `TestSupport`, the demo seeders — so the one line that was
/// missing, the folder creation inside the writer, was the one line nothing exercised.
/// A test that builds its own sample buffers and asserts a playable file appears is the
/// only kind that could have caught it.
final class SegmentWriterTests: XCTestCase {
    private var sessionID: UUID!

    override func setUp() {
        super.setUp()
        sessionID = UUID()
    }

    override func tearDown() {
        let folder = StorageLocations.recordingsRoot.appendingPathComponent(sessionID.uuidString)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Frame factory

    private func makeSampleBuffer(width: Int, height: Int, pts: CMTime, fill: UIColor? = nil) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        if let fill {
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.setFillColor(fill.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }

        var formatDescription: CMFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription
        ), noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeWriter(
        segmentSeconds: TimeInterval = 60,
        onFinished: @escaping @Sendable (FinishedSegment) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void = { XCTFail("writer failed: \($0)") }
    ) -> SegmentWriter {
        SegmentWriter(
            camera: .rear,
            sessionID: sessionID,
            format: VideoFormatDescriptor.resolved(for: .eco, codec: AVVideoCodecType.h264.rawValue),
            includesAudio: false,
            segmentDuration: segmentSeconds,
            onSegmentFinished: onFinished,
            onFailure: onFailure
        )
    }

    /// Feeds `count` frames at 30 fps starting at `from`.
    private func feed(_ writer: SegmentWriter, frames count: Int, width: Int = 640, height: Int = 360, from: Double = 0, fill: UIColor? = nil) throws {
        for index in 0..<count {
            let pts = CMTime(seconds: from + Double(index) / 30, preferredTimescale: 600)
            writer.appendVideo(try makeSampleBuffer(width: width, height: height, pts: pts, fill: fill))
        }
    }

    private func stopAndWait(_ writer: SegmentWriter, timeout: TimeInterval = 20) {
        let finished = expectation(description: "writer stopped")
        writer.stop { finished.fulfill() }
        wait(for: [finished], timeout: timeout)
    }

    // MARK: Tests

    /// The regression: a session folder that does not exist yet must not stop the writer.
    func testItWritesAPlayableFileWhenTheSessionFolderDoesNotExistYet() throws {
        let folder = StorageLocations.recordingsRoot.appendingPathComponent(sessionID.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "precondition: no folder")

        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        try feed(writer, frames: 30)
        stopAndWait(writer)

        let segments = box.values
        XCTAssertEqual(segments.count, 1)
        let segment = try XCTUnwrap(segments.first)
        XCTAssertTrue(segment.succeeded, "the writer reported failure")

        let url = StorageLocations.absoluteURL(forRelativePath: segment.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "no file on disk")
        XCTAssertGreaterThan(segment.fileSize, 0)
    }

    func testTheFileIsReadableAsAMovie() async throws {
        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        try feed(writer, frames: 45)
        stopAndWait(writer)

        let segment = try XCTUnwrap(box.values.first)
        let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.5, "45 frames at 30 fps is 1.5 s")
    }

    /// The scheduled boundary: two segments out of a stream longer than one window.
    func testItCutsANewSegmentAtTheScheduledBoundary() throws {
        let box = SegmentBox()
        let writer = makeWriter(segmentSeconds: 1, onFinished: { box.append($0) })
        try feed(writer, frames: 75)   // 2.5 s at 30 fps, so three windows are touched
        stopAndWait(writer)

        let indexes = box.values.map(\.index).sorted()
        XCTAssertGreaterThanOrEqual(box.values.count, 2, "a 2.5 s stream spans more than one 1 s window")
        XCTAssertEqual(indexes, Array(0..<box.values.count), "indexes run without a gap")
        XCTAssertTrue(box.values.allSatisfy(\.succeeded))
    }

    /// Turning the phone mid-window must not cut the file, and must not change its shape.
    ///
    /// Asserts the **file on disk**, not the metadata row. The previous version of this
    /// test checked `FinishedSegment.width`, which is simply what the app claimed it wrote
    /// — it would have passed even if the encoder ignored the requested dimensions
    /// entirely, which is exactly the failure it was supposed to catch.
    func testTheFileOnDiskIsLandscapeEvenWhenTheFramesArrivePortrait() async throws {
        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        try feed(writer, frames: 20, width: 360, height: 640)   // upright frames only
        stopAndWait(writer)

        XCTAssertEqual(box.values.count, 1)
        let segment = try XCTUnwrap(box.values.first)

        let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // What a player actually shows: the natural size with the transform applied.
        let displayed = CGRect(origin: .zero, size: natural).applying(transform)

        XCTAssertGreaterThan(abs(displayed.width), abs(displayed.height),
                             "the file plays portrait: \(natural) transform \(transform)")
        XCTAssertEqual(abs(displayed.width), 1280, accuracy: 2, "Eco is 1280 wide")
        XCTAssertEqual(abs(displayed.height), 720, accuracy: 2)
    }

    /// The point of the whole landscape lock: an upright source must come out as a
    /// **full-frame** landscape picture, not a narrow strip between black bars.
    ///
    /// Sampling the corners is the only way to tell those two apart — both produce a file
    /// whose dimensions are 1280×720, and every dimension assertion passes either way.
    func testAnUprightSourceFillsTheLandscapeFrameWithoutBars() async throws {
        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        try feed(writer, frames: 30, width: 360, height: 640,
                 fill: UIColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1))
        stopAndWait(writer)

        let segment = try XCTUnwrap(box.values.first)
        let asset = AVURLAsset(url: StorageLocations.absoluteURL(forRelativePath: segment.relativePath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)

        XCTAssertGreaterThan(image.width, image.height, "the file is not landscape")
        for (label, x) in [("left", 0.05), ("right", 0.95)] {
            let colour = Self.sample(image, x: x, y: 0.5)
            XCTAssertGreaterThan(colour.g, 60, "\(label) edge is a black bar, not picture: \(colour)")
        }
    }

    static func sample(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let px = min(width - 1, max(0, Int(Double(width) * x)))
        let py = min(height - 1, max(0, Int(Double(height) * y)))
        let offset = (py * width + px) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    func testASingleWindowStaysOneFileWhateverTheFrameShape() throws {
        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        try feed(writer, frames: 20, width: 640, height: 360)
        try feed(writer, frames: 20, width: 360, height: 640, from: 20.0 / 30)
        stopAndWait(writer)

        XCTAssertEqual(box.values.count, 1, "one window, one file, whichever way the phone was held")
    }

    /// Every segment of a drive is the same size, which is what lets them concatenate.
    func testEverySegmentHasTheSameLandscapeShape() throws {
        let box = SegmentBox()
        let writer = makeWriter(segmentSeconds: 1, onFinished: { box.append($0) })
        try feed(writer, frames: 30, width: 640, height: 360)
        try feed(writer, frames: 45, width: 360, height: 640, from: 1.0)
        stopAndWait(writer)

        let shapes = Set(box.values.map { "\($0.width)x\($0.height)" })
        XCTAssertEqual(shapes.count, 1, "the output shape never varies: \(shapes)")
        XCTAssertTrue(box.values.allSatisfy { $0.width > $0.height })
    }

    func testStoppingWithoutAnyFrameProducesNothingAndDoesNotHang() {
        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        stopAndWait(writer, timeout: 5)
        XCTAssertTrue(box.values.isEmpty)
    }
}

/// Collects callbacks that arrive on the writer's own queue.
private final class SegmentBox: @unchecked Sendable {
    private var storage: [FinishedSegment] = []
    private let lock = NSLock()

    func append(_ segment: FinishedSegment) {
        lock.lock(); storage.append(segment); lock.unlock()
    }

    var values: [FinishedSegment] {
        lock.lock(); defer { lock.unlock() }
        return storage.sorted { ($0.index, $0.relativePath) < ($1.index, $1.relativePath) }
    }
}
