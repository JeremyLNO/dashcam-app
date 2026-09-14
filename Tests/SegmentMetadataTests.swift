import AVFoundation
import CoreLocation
import XCTest
@testable import Dashcam

/// What a recorded file says about itself, read back from the file.
///
/// Asserted by opening the `.mov` and asking AVFoundation, never by inspecting the
/// dictionary the app handed over: the point of this feature is that a stranger's tool
/// can read those fields, and a test that checks its own input proves nothing about that.
final class SegmentMetadataTests: XCTestCase {
    private let sessionID = UUID()
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("meta-\(UUID().uuidString).mov")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a real movie carrying the file-level metadata, then reads it back.
    private func writeMovie(location: CLLocation?) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = SegmentMetadata.fileLevel(
            sessionID: sessionID,
            camera: .rear,
            segmentIndex: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            location: location
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Frames, not an empty track: a movie whose video track carries no sample is
        // rejected as damaged, and the first version of this test proved only that.
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        for frame in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 4))
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 4))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "the fixture movie must be written before it can be read")
    }

    private func metadata() async throws -> [AVMetadataItem] {
        try await AVURLAsset(url: url).load(.metadata)
    }

    private func value(of identifier: String, in items: [AVMetadataItem]) async throws -> String? {
        for item in items where item.identifier?.rawValue == identifier {
            return try await item.load(.stringValue)
        }
        return nil
    }

    func testAFileNamesTheAppThatWroteIt() async throws {
        try await writeMovie(location: nil)
        let items = try await metadata()

        let software = try await value(of: AVMetadataIdentifier.quickTimeMetadataSoftware.rawValue, in: items)
        XCTAssertNotNil(software)
        XCTAssertTrue(software?.contains("Dashcam") == true, "got \(software ?? "nil")")
    }

    func testAFileCarriesItsDriveAndItsPlaceInIt() async throws {
        try await writeMovie(location: nil)
        let items = try await metadata()

        let session = try await value(of: SegmentMetadata.identifier(for: "session"), in: items)
        XCTAssertEqual(session, sessionID.uuidString)

        let camera = try await value(of: SegmentMetadata.identifier(for: "camera"), in: items)
        XCTAssertEqual(camera, CameraPosition.rear.rawValue)
    }

    /// The creation date is the one field every tool reads, so it has to be the recording
    /// time rather than the moment the file happened to be closed.
    func testTheCreationDateIsWhenTheSegmentStarted() async throws {
        try await writeMovie(location: nil)
        let items = try await metadata()

        let stamp = try await value(of: AVMetadataIdentifier.quickTimeMetadataCreationDate.rawValue, in: items)
        XCTAssertEqual(stamp?.hasPrefix("2023-11-14"), true, "got \(stamp ?? "nil")")
    }

    func testAPositionIsWrittenInTheFormatQuickTimeExpects() async throws {
        let paris = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945),
            altitude: 33, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 0, speed: 13.9, timestamp: Date()
        )
        try await writeMovie(location: paris)
        let items = try await metadata()

        let iso = try await value(of: AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue, in: items)
        XCTAssertEqual(iso, "+48.8584+002.2945+33.0/")
    }

    /// A drive recorded without location permission must not claim to have been filmed
    /// off the coast of Africa, which is what a zeroed coordinate reads as.
    func testNoPositionIsWrittenWhenThereIsNone() async throws {
        try await writeMovie(location: nil)
        let items = try await metadata()

        let iso = try await value(of: AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue, in: items)
        XCTAssertNil(iso, "an absent position is honest; a zeroed one is a false claim")
    }

    /// The ISO 6709 encoder, on the values that break naive formatting: the southern and
    /// western hemispheres, where the sign is the whole meaning.
    func testTheCoordinateFormatCarriesItsSigns() {
        let sydney = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
            altitude: 58, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()
        )
        XCTAssertEqual(SegmentMetadata.iso6709(sydney), "-33.8688+151.2093+58.0/")

        let reykjavik = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0, timestamp: Date()
        )
        XCTAssertEqual(SegmentMetadata.iso6709(reykjavik), "+64.1466-021.9426+0.0/")
    }
}
