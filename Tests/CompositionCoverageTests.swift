import AVFoundation
import SwiftData
import UIKit
import XCTest
@testable import Dashcam

/// Whether the instruction list actually covers the footage it is supposed to lay out.
///
/// This is the shape the "black video" defect takes. AVFoundation asks for a list of
/// instructions covering the timeline, and for any instant no instruction claims — or that
/// an instruction claims while drawing nothing — it renders the background colour, which is
/// black. It reports nothing: no error, no failed player item, no log line. Footage and a
/// black rectangle come back through the same API in the same state.
///
/// So the list is checked here, and checked *exactly*. A hole of one frame and a hole of
/// the whole drive are the same defect measured on different footage.
@MainActor
final class CompositionCoverageTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var sessionID: UUID!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

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

    // MARK: - The check itself

    private func instruction(from: Double, to: Double, layers: Int = 1) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: 600),
            end: CMTime(seconds: to, preferredTimescale: 600)
        )
        let track = AVMutableComposition().addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        instruction.layerInstructions = (0..<layers).map { _ in
            AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        }
        return instruction
    }

    private func composition(_ instructions: [AVMutableVideoCompositionInstruction]) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: 1280, height: 720)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return videoComposition
    }

    private let tenSeconds = CMTime(seconds: 10, preferredTimescale: 600)

    func testAListThatTilesTheTimelineIsSilent() {
        let built = composition([instruction(from: 0, to: 4), instruction(from: 4, to: 10)])
        XCTAssertEqual(CompositionDiagnostics.problems(in: built, duration: tenSeconds), [])
    }

    func testAHoleInTheMiddleIsNamed() {
        let built = composition([instruction(from: 0, to: 4), instruction(from: 5, to: 10)])
        XCTAssertEqual(
            CompositionDiagnostics.problems(in: built, duration: tenSeconds),
            [.gap(from: 4, to: 5)]
        )
    }

    /// The one that matters most: instructions that stop early. Nothing downstream fails,
    /// the drive simply goes black at the end.
    func testATailNobodyCoversIsNamed() {
        let built = composition([instruction(from: 0, to: 9)])
        XCTAssertEqual(
            CompositionDiagnostics.problems(in: built, duration: tenSeconds),
            [.uncoveredTail(from: 9, to: 10)]
        )
    }

    func testAnInstructionWithNothingToDrawIsNamed() {
        let built = composition([instruction(from: 0, to: 10, layers: 0)])
        XCTAssertEqual(
            CompositionDiagnostics.problems(in: built, duration: tenSeconds),
            [.nothingToDraw(at: 0)]
        )
    }

    func testAnEmptyListIsNamed() {
        XCTAssertEqual(CompositionDiagnostics.problems(in: composition([]), duration: tenSeconds), [.noInstructions])
    }

    // MARK: - The compositions the app actually builds

    /// Clips whose durations are deliberately not round: the road camera runs at a rate
    /// whose frames do not land on the timeline's own ticks, and the cabin camera at a
    /// different one again. Real footage is like this — two cameras cut their segments from
    /// their own first frame, milliseconds apart — and it is exactly what arithmetic done
    /// in seconds loses.
    private func stageUnevenSegments(count: Int = 3) async throws {
        for segmentIndex in 0..<count {
            for (camera, colour, rate, extra) in [
                (CameraPosition.rear, UIColor.red, 7, 1),
                (CameraPosition.front, UIColor.blue, 15, 0),
            ] {
                let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: segmentIndex)
                let url = StorageLocations.prepareURL(forRelativePath: relativePath)
                let written = await DemoDataSeeder.writeSolidColourMovie(
                    to: url, colour: colour, size: CGSize(width: 1280, height: 720),
                    seconds: 2, frameRate: rate, extraFrames: extra
                )
                XCTAssertTrue(written, "could not stage the \(camera.rawValue) clip")

                index.insertSegment(FinishedSegment(
                    camera: camera, index: segmentIndex,
                    startDate: start.addingTimeInterval(Double(segmentIndex) * 2),
                    endDate: start.addingTimeInterval(Double(segmentIndex + 1) * 2),
                    relativePath: relativePath,
                    fileSize: StorageManager.fileSize(at: url),
                    width: 1280, height: 720, fps: 30,
                    codec: AVVideoCodecType.h264.rawValue, succeeded: true
                ), sessionID: sessionID, isProtected: false)
            }
        }
    }

    func testTheTwoUpCompositionCoversItsWholeTimeline() async throws {
        try await stageUnevenSegments()
        let session = try XCTUnwrap(index.session(id: sessionID))

        let built = try await SessionComposition.pictureInPicture(
            rear: session.rearSegments, front: session.frontSegments, includeAudio: false
        )
        let videoComposition = try XCTUnwrap(built.videoComposition)

        let problems = CompositionDiagnostics.problems(in: videoComposition, duration: built.duration)
        XCTAssertEqual(problems, [], "the two-up player would render black where nothing covers it: \(problems)")
    }

    func testTheSingleCameraCompositionCoversItsWholeTimeline() async throws {
        try await stageUnevenSegments()
        let session = try XCTUnwrap(index.session(id: sessionID))

        let built = try await SessionComposition.singleWithLayout(
            segments: session.rearSegments, includeAudio: false
        )
        let videoComposition = try XCTUnwrap(built.videoComposition)

        let problems = CompositionDiagnostics.problems(in: videoComposition, duration: built.duration)
        XCTAssertEqual(problems, [], "\(problems)")
    }

    /// The cabin camera stopping early — shed for heat, or simply a shorter last segment —
    /// must not take the road footage down with it. The slices after the cabin ends still
    /// have the road to draw.
    func testTheRoadKeepsItsInstructionsAfterTheCabinStops() async throws {
        try await stageUnevenSegments(count: 3)
        // Drop the cabin's last segment, leaving the road running past it.
        let session = try XCTUnwrap(index.session(id: sessionID))
        let front = Array(session.frontSegments.dropLast())

        let built = try await SessionComposition.pictureInPicture(
            rear: session.rearSegments, front: front, includeAudio: false
        )
        let videoComposition = try XCTUnwrap(built.videoComposition)

        let problems = CompositionDiagnostics.problems(in: videoComposition, duration: built.duration)
        XCTAssertEqual(problems, [], "\(problems)")
    }
}
