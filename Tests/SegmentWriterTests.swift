import AVFoundation
import CoreVideo
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

    private func makeSampleBuffer(width: Int, height: Int, pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

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
    private func feed(_ writer: SegmentWriter, frames count: Int, width: Int = 640, height: Int = 360, from: Double = 0) throws {
        for index in 0..<count {
            let pts = CMTime(seconds: from + Double(index) / 30, preferredTimescale: 600)
            writer.appendVideo(try makeSampleBuffer(width: width, height: height, pts: pts))
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

    /// Turning the phone changes the frame shape, which an open input cannot accept — the
    /// writer has to cut, and both files have to survive.
    func testItCutsWhenTheFrameGeometryChanges() throws {
        let box = SegmentBox()
        let writer = makeWriter(onFinished: { box.append($0) })
        try feed(writer, frames: 20, width: 640, height: 360)
        try feed(writer, frames: 20, width: 360, height: 640, from: 20.0 / 30)
        stopAndWait(writer)

        XCTAssertEqual(box.values.count, 2, "one file per geometry")
        let sizes = Set(box.values.map { "\($0.width)x\($0.height)" })
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(Set(box.values.map(\.index)), [0], "same window, so the index does not move")
        XCTAssertEqual(Set(box.values.map(\.relativePath)).count, 2, "distinct paths")
        XCTAssertTrue(box.values.allSatisfy(\.succeeded))
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
