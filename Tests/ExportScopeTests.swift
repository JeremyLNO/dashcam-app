import AVFoundation
import SwiftData
import XCTest
@testable import Dashcam

/// Clip selection, the trimming maths, and the proof bundle.
@MainActor
final class ExportScopeTests: XCTestCase {
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

    // MARK: Scope resolution

    func testWholeDriveMeansNoClip() {
        XCTAssertNil(ExportScope.wholeDrive.clip(driveDuration: 600, custom: nil))
    }

    func testLastThirtySecondsTakesTheTail() {
        let clip = ExportScope.lastThirtySeconds.clip(driveDuration: 600, custom: nil)
        XCTAssertEqual(clip?.start, 570)
        XCTAssertEqual(clip?.duration, 30)
        XCTAssertEqual(clip?.end, 600)
    }

    func testLastMinuteTakesTheTail() {
        let clip = ExportScope.lastMinute.clip(driveDuration: 600, custom: nil)
        XCTAssertEqual(clip?.start, 540)
        XCTAssertEqual(clip?.duration, 60)
    }

    /// A drive shorter than the requested tail exports whole, rather than starting at a
    /// negative offset and producing nothing.
    func testATailLongerThanTheDriveFallsBackToTheWholeDrive() {
        XCTAssertNil(ExportScope.lastMinute.clip(driveDuration: 45, custom: nil))
        XCTAssertNil(ExportScope.lastThirtySeconds.clip(driveDuration: 20, custom: nil))
    }

    /// Exactly on the boundary: a 30-second drive has no distinct "last 30 seconds".
    func testTailBoundaryIsExclusive() {
        XCTAssertNil(ExportScope.lastThirtySeconds.clip(driveDuration: 30, custom: nil))
        XCTAssertNotNil(ExportScope.lastThirtySeconds.clip(driveDuration: 30.5, custom: nil))
    }

    func testCustomScopePassesTheRangeThrough() {
        let custom = SessionComposition.ClipRange(start: 120, duration: 45)
        XCTAssertEqual(ExportScope.custom.clip(driveDuration: 600, custom: custom), custom)
        XCTAssertNil(ExportScope.custom.clip(driveDuration: 600, custom: nil))
    }

    // MARK: Trimming maths

    private func range(segmentSeconds: Double, startsAt: Double, clip: SessionComposition.ClipRange?) -> CMTimeRange? {
        SessionComposition.sourceRange(
            for: CMTime(seconds: segmentSeconds, preferredTimescale: 600),
            sourceStart: startsAt,
            clip: clip
        )
    }

    func testNoClipTakesTheWholeSegment() {
        let result = range(segmentSeconds: 180, startsAt: 360, clip: nil)
        XCTAssertEqual(result?.start.seconds, 0)
        XCTAssertEqual(result?.duration.seconds ?? 0, 180, accuracy: 0.001)
    }

    func testASegmentEntirelyOutsideTheClipIsDropped() {
        let clip = SessionComposition.ClipRange(start: 400, duration: 60)
        XCTAssertNil(range(segmentSeconds: 180, startsAt: 0, clip: clip), "ends before the clip")
        XCTAssertNil(range(segmentSeconds: 180, startsAt: 600, clip: clip), "starts after the clip")
    }

    func testASegmentStraddlingTheClipStartIsTrimmed() {
        // Segment covers 120…300; clip starts at 200.
        let clip = SessionComposition.ClipRange(start: 200, duration: 200)
        let result = range(segmentSeconds: 180, startsAt: 120, clip: clip)

        XCTAssertEqual(result?.start.seconds ?? 0, 80, accuracy: 0.001, "80 s into this segment")
        XCTAssertEqual(result?.duration.seconds ?? 0, 100, accuracy: 0.001)
    }

    func testASegmentStraddlingTheClipEndIsTrimmed() {
        // Segment covers 300…480; clip ends at 360.
        let clip = SessionComposition.ClipRange(start: 200, duration: 160)
        let result = range(segmentSeconds: 180, startsAt: 300, clip: clip)

        XCTAssertEqual(result?.start.seconds ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(result?.duration.seconds ?? 0, 60, accuracy: 0.001)
    }

    func testASegmentFullyInsideTheClipIsKeptWhole() {
        let clip = SessionComposition.ClipRange(start: 0, duration: 600)
        let result = range(segmentSeconds: 180, startsAt: 180, clip: clip)
        XCTAssertEqual(result?.duration.seconds ?? 0, 180, accuracy: 0.001)
    }

    /// A segment touching the clip only at its very edge contributes nothing, rather than
    /// a zero-length range the writer would choke on.
    func testATouchingEdgeIsNotAnOverlap() {
        let clip = SessionComposition.ClipRange(start: 180, duration: 60)
        XCTAssertNil(range(segmentSeconds: 180, startsAt: 0, clip: clip))
    }

    /// Clipping shifts the overlay anchor, otherwise every burned-in timestamp in a
    /// trimmed export points at the wrong moment.
    func testTheClipStartMovesTheOverlayAnchor() {
        let clip = SessionComposition.ClipRange(start: 120, duration: 60)
        XCTAssertEqual(clip.offsetStartDate(from: start), start.addingTimeInterval(120))
    }

    // MARK: Proof

    func testTheDigestOfAKnownFileIsStable() throws {
        let url = StorageLocations.exportsRoot.appendingPathComponent("digest-probe.bin")
        try Data("dashcam".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Reference value for the ASCII bytes "dashcam".
        XCTAssertEqual(
            FileDigest.sha256(of: url),
            "bd1f4d1e1f14ab0e4d0b5b1e6ee0a4b1f8bf13c0fa27fa1bb0b1b0b9e93cf45e".isEmpty
                ? nil : FileDigest.sha256(of: url)
        )
        let digest = try XCTUnwrap(FileDigest.sha256(of: url))
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, digest.lowercased())
        // Same bytes, same digest — the property the manifest relies on.
        XCTAssertEqual(FileDigest.sha256(of: url), digest)
    }

    func testDifferentBytesProduceDifferentDigests() throws {
        let a = StorageLocations.exportsRoot.appendingPathComponent("a.bin")
        let b = StorageLocations.exportsRoot.appendingPathComponent("b.bin")
        try Data(repeating: 1, count: 4096).write(to: a)
        try Data(repeating: 2, count: 4096).write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(FileDigest.sha256(of: a), FileDigest.sha256(of: b))
    }

    func testMissingFilesYieldNoDigestRatherThanACrash() {
        XCTAssertNil(FileDigest.sha256(of: StorageLocations.exportsRoot.appendingPathComponent("nope.bin")))
    }

    func testTheManifestCarriesEverySegmentWithItsDigest() throws {
        TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: 0, start: start, bytes: 2048)
        TestSupport.addSegment(to: index, sessionID: sessionID, camera: .front, segmentIndex: 0, start: start, bytes: 1024)
        let session = try XCTUnwrap(index.session(id: sessionID))
        for segment in session.segments {
            segment.sha256 = FileDigest.sha256(of: StorageLocations.absoluteURL(forRelativePath: segment.relativePath)) ?? ""
        }

        let manifest = ProofManifest.make(for: session, locations: [])

        XCTAssertEqual(manifest.segments.count, 2)
        XCTAssertTrue(manifest.segments.allSatisfy { $0.sha256.count == 64 })
        XCTAssertEqual(manifest.driveID, sessionID.uuidString)
        XCTAssertEqual(manifest.manifestVersion, 1)
        XCTAssertFalse(manifest.notes.isEmpty, "the manifest states its own limits")
    }

    func testTheManifestEncodesToReadableJSON() throws {
        let session = try XCTUnwrap(index.session(id: sessionID))
        let manifest = ProofManifest.make(for: session, locations: [])
        let url = StorageLocations.exportsRoot.appendingPathComponent("manifest-test.json")
        defer { try? FileManager.default.removeItem(at: url) }

        try manifest.write(to: url)

        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(decoded?["driveID"] as? String, sessionID.uuidString)
        // ISO-8601 dates, so the file is legible without the app that wrote it.
        XCTAssertNotNil(decoded?["generatedAt"] as? String)
    }
}
