import AVFoundation
import CoreVideo
import UIKit
import XCTest
@testable import Dashcam

/// Exercises the layer that routes camera frames to two writers at once.
///
/// `SegmentWriter` was tested alone and the composition was tested alone, but nothing ever
/// tested the thing in between — the engine that decides which writer a frame belongs to
/// and whether a cabin writer exists at all. "The cabin camera is missing" has to be ruled
/// in or out here before blaming AVFoundation.
final class RecordingEngineTests: XCTestCase {
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

    private func makeBuffer(pts: CMTime, width: Int = 640, height: Int = 360) throws -> CMSampleBuffer {
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
            duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func configuration(includesFront: Bool) -> RecordingEngine.Configuration {
        let format = VideoFormatDescriptor.resolved(for: .eco, codec: AVVideoCodecType.h264.rawValue)
        return RecordingEngine.Configuration(
            sessionID: sessionID,
            rearFormat: format,
            frontFormat: format,
            includesFront: includesFront,
            includesAudio: false,
            segmentDuration: 60
        )
    }

    /// Feeds both cameras for `frames` frames and returns what came back.
    private func run(includesFront: Bool, frames: Int = 30) throws -> [FinishedSegment] {
        let engine = RecordingEngine()
        let collected = Collected()
        engine.onSegmentFinished = { segment, _ in collected.append(segment) }
        engine.onFailure = { XCTFail("engine reported failure: \($0)") }

        engine.start(configuration(includesFront: includesFront))
        for index in 0..<frames {
            let pts = CMTime(seconds: Double(index) / 30, preferredTimescale: 600)
            engine.consume(try makeBuffer(pts: pts), from: .rearVideo)
            engine.consume(try makeBuffer(pts: pts), from: .frontVideo)
        }

        let stopped = expectation(description: "engine stopped")
        engine.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 20)
        return collected.values
    }

    // MARK: Tests

    /// The one that matters: both cameras must produce a file.
    func testItWritesOneFilePerCamera() throws {
        let segments = try run(includesFront: true)

        XCTAssertEqual(Set(segments.map(\.camera)), [.rear, .front],
                       "cameras written: \(segments.map(\.camera.rawValue))")
        XCTAssertEqual(segments.count, 2)
        for segment in segments {
            XCTAssertTrue(segment.succeeded, "\(segment.camera.rawValue) failed")
            let url = StorageLocations.absoluteURL(forRelativePath: segment.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "no file for \(segment.camera.rawValue)")
            XCTAssertGreaterThan(segment.fileSize, 0)
        }
    }

    /// Both cameras cover the same window, which is what the two-up player pairs on.
    func testBothCamerasShareTheSameSegmentIndex() throws {
        let segments = try run(includesFront: true)
        XCTAssertEqual(Set(segments.map(\.index)), [0])
    }

    /// Cabin off, or a phone that cannot do multi-cam: the road must still record, and no
    /// stray cabin file may appear.
    func testWithoutTheCabinOnlyTheRoadIsWritten() throws {
        let segments = try run(includesFront: false)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.camera, .rear)
    }

    /// Frames that arrive before `start` must not crash or leak a file.
    func testFramesBeforeStartAreIgnored() throws {
        let engine = RecordingEngine()
        let collected = Collected()
        engine.onSegmentFinished = { segment, _ in collected.append(segment) }

        engine.consume(try makeBuffer(pts: .zero), from: .frontVideo)
        XCTAssertFalse(engine.isRecording)

        let stopped = expectation(description: "stopped")
        engine.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
        XCTAssertTrue(collected.values.isEmpty)
    }

    /// Shedding the cabin for heat must close its file and leave the road untouched.
    ///
    /// The cabin's finalization is fire-and-forget — `dropFrontCamera` does not block, and
    /// the engine's own `stop` no longer knows about that writer — so the test waits for
    /// both callbacks rather than for the engine, which is also the guarantee the app
    /// relies on: every finished file eventually reaches the index.
    func testDroppingTheCabinKeepsTheRoadRecording() throws {
        let engine = RecordingEngine()
        let collected = Collected()
        let bothIndexed = expectation(description: "both cameras reported")
        bothIndexed.expectedFulfillmentCount = 2
        engine.onSegmentFinished = { segment, _ in
            collected.append(segment)
            bothIndexed.fulfill()
        }
        engine.start(configuration(includesFront: true))

        for index in 0..<15 {
            let pts = CMTime(seconds: Double(index) / 30, preferredTimescale: 600)
            engine.consume(try makeBuffer(pts: pts), from: .rearVideo)
            engine.consume(try makeBuffer(pts: pts), from: .frontVideo)
        }
        engine.dropFrontCamera()
        for index in 15..<30 {
            let pts = CMTime(seconds: Double(index) / 30, preferredTimescale: 600)
            engine.consume(try makeBuffer(pts: pts), from: .rearVideo)
        }

        let stopped = expectation(description: "stopped")
        engine.stop { stopped.fulfill() }
        wait(for: [stopped, bothIndexed], timeout: 20)

        XCTAssertEqual(Set(collected.values.map(\.camera)), [.rear, .front])
        XCTAssertTrue(collected.values.allSatisfy(\.succeeded))
    }
}

private final class Collected: @unchecked Sendable {
    private var storage: [FinishedSegment] = []
    private let lock = NSLock()
    func append(_ segment: FinishedSegment) { lock.lock(); storage.append(segment); lock.unlock() }
    var values: [FinishedSegment] { lock.lock(); defer { lock.unlock() }; return storage }
}
