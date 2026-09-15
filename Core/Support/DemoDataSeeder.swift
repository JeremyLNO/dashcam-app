import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// Writes a small, *real* library so UI tests exercise the same code paths as a user.
///
/// The movies are genuine encoded files, not stubs: the library, the two-up player and
/// the export pipeline all run against actual assets, which is the only way a UI test of
/// "export is blocked during the trial" proves anything.
///
/// Only ever invoked behind the `-uiTestSeed` launch argument.
@MainActor
struct DemoDataSeeder {
    let index: SessionIndex

    func seed(sessions sessionCount: Int = 2, segmentsPerSession: Int = 3) async {
        guard index.allSessions().isEmpty else { return }

        let now = Date()
        for sessionOffset in 0..<sessionCount {
            let start = now.addingTimeInterval(-Double(sessionOffset + 1) * 3600)
            let sessionID = UUID()
            index.beginSession(id: sessionID, startedAt: start, quality: .standard)

            for segmentIndex in 0..<segmentsPerSession {
                let segmentStart = start.addingTimeInterval(Double(segmentIndex) * 2)
                for camera in CameraPosition.allCases {
                    let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: segmentIndex)
                    let url = StorageLocations.absoluteURL(forRelativePath: relativePath)
                    let written = await Self.writeSolidColourMovie(
                        to: url,
                        colour: camera == .rear ? UIColor(white: 0.18, alpha: 1) : UIColor(white: 0.32, alpha: 1),
                        size: CGSize(width: 640, height: 360),
                        seconds: 2
                    )
                    guard written else { continue }

                    let finished = FinishedSegment(
                        camera: camera,
                        index: segmentIndex,
                        startDate: segmentStart,
                        endDate: segmentStart.addingTimeInterval(2),
                        relativePath: relativePath,
                        fileSize: StorageManager.fileSize(at: url),
                        width: 640, height: 360, fps: 30,
                        codec: AVVideoCodecType.h264.rawValue,
                        succeeded: true
                    )
                    index.insertSegment(finished, sessionID: sessionID, isProtected: false)
                }
            }
            index.endSession(id: sessionID, endedAt: start.addingTimeInterval(Double(segmentsPerSession) * 2))
        }
        index.save()
    }

    /// Encodes a few seconds of a flat colour. Returns false if the encoder is
    /// unavailable, so a seeding failure degrades to "no demo footage" rather than
    /// crashing the harness.
    /// `frameRate` and `extraFrames` exist for the tests: together they produce a clip
    /// whose duration is deliberately *not* a round number of timeline ticks, which is the
    /// shape real footage has and the shape that catches arithmetic done in seconds.
    static func writeSolidColourMovie(
        to url: URL, colour: UIColor, size: CGSize, seconds: Int,
        frameRate: Int = 15, extraFrames: Int = 0
    ) async -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        // Every frame a keyframe, and no reordering. These clips exist to be decoded at an
        // arbitrary instant — by the tests that sample their pixels, and by the library
        // preview — and a frame that can only be reconstructed from a distant reference is
        // what makes such a read come back half-decoded under load.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return false }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        guard let buffer = makePixelBuffer(colour: colour, size: size) else {
            writer.cancelWriting()
            return false
        }

        let fps = frameRate
        let frames = seconds * fps + extraFrames
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }

    private static func makePixelBuffer(colour: UIColor, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.setFillColor(colour.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return buffer
    }
}
