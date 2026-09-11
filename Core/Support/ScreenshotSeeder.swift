import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// Builds a believable library for App Store screenshots.
///
/// Separate from `DemoDataSeeder`, which exists for UI tests and is deliberately minimal
/// and deterministic. This one optimises for a different thing: every number a screenshot
/// puts on screen has to be internally consistent. A drive that says "9 segments" and
/// "29 KB" in the same row looks broken, so the files written here are real 1080p clips
/// sized to match the story their metadata tells.
///
/// Only ever invoked behind the `-screenshotSeed` launch argument.
@MainActor
struct ScreenshotSeeder {
    let index: SessionIndex

    private struct Drive {
        let minutesAgo: Int
        let segmentCount: Int
        let kilometres: Double
        let peakG: Double
        /// Offsets, in seconds from the drive's start, of the events to stage.
        let events: [(offset: TimeInterval, origin: ProtectionOrigin, magnitude: Double)]
    }

    /// One minute per segment: short segments give the timeline enough marks to read, and
    /// keep the generated files small enough to write in a few seconds.
    private static let segmentSeconds: TimeInterval = 60

    private static let drives: [Drive] = [
        Drive(minutesAgo: 95, segmentCount: 9, kilometres: 7.4, peakG: 2.91, events: [
            (offset: 286, origin: .harshBraking, magnitude: 0.58),
            (offset: 412, origin: .impact, magnitude: 2.91),
        ]),
        Drive(minutesAgo: 260, segmentCount: 6, kilometres: 5.1, peakG: 0.62, events: [
            (offset: 174, origin: .manual, magnitude: 0),
        ]),
        Drive(minutesAgo: 1_450, segmentCount: 4, kilometres: 3.2, peakG: 0.34, events: []),
        Drive(minutesAgo: 1_610, segmentCount: 3, kilometres: 2.6, peakG: 0.29, events: []),
    ]

    func seed() async {
        guard index.allSessions().isEmpty else { return }
        let now = Date()

        for drive in Self.drives {
            let start = now.addingTimeInterval(-Double(drive.minutesAgo) * 60)
            let sessionID = UUID()
            index.beginSession(id: sessionID, startedAt: start, quality: .standard)

            for segmentIndex in 0..<drive.segmentCount {
                let segmentStart = start.addingTimeInterval(Double(segmentIndex) * Self.segmentSeconds)
                for camera in CameraPosition.allCases {
                    await write(
                        camera: camera,
                        sessionID: sessionID,
                        segmentIndex: segmentIndex,
                        start: segmentStart
                    )
                }
            }

            index.endSession(
                id: sessionID,
                endedAt: start.addingTimeInterval(Double(drive.segmentCount) * Self.segmentSeconds)
            )
            index.updateStatistics(sessionID: sessionID, addingMetres: drive.kilometres * 1000, peakG: drive.peakG)
            stageSensorTrace(sessionID: sessionID, start: start, drive: drive)

            for event in drive.events {
                let triggered = start.addingTimeInterval(event.offset)
                guard let record = index.insertProtectedEvent(
                    sessionID: sessionID, triggerDate: triggered,
                    origin: event.origin, magnitude: event.magnitude
                ) else { continue }
                if let session = index.session(id: sessionID) {
                    for segment in session.segments where record.covers(segment) {
                        segment.isProtected = true
                    }
                }
            }
        }
        index.save()
    }

    private func write(camera: CameraPosition, sessionID: UUID, segmentIndex: Int, start: Date) async {
        let relativePath = StorageLocations.relativePath(sessionID: sessionID, camera: camera, index: segmentIndex)
        let url = StorageLocations.absoluteURL(forRelativePath: relativePath)
        guard await Self.writeClip(to: url, camera: camera) else { return }

        let finished = FinishedSegment(
            camera: camera,
            index: segmentIndex,
            startDate: start,
            endDate: start.addingTimeInterval(Self.segmentSeconds),
            relativePath: relativePath,
            fileSize: StorageManager.fileSize(at: url),
            width: 1920, height: 1080, fps: 30,
            codec: AVVideoCodecType.hevc.rawValue,
            succeeded: true
        )
        index.insertSegment(finished, sessionID: sessionID, isProtected: false)
    }

    /// A plausible speed and G-force trace, so the drive's detail screen has something
    /// real to show rather than empty rows.
    private func stageSensorTrace(sessionID: UUID, start: Date, drive: Drive) {
        let duration = Double(drive.segmentCount) * Self.segmentSeconds
        var travelled: Double = 0
        let metresPerSecond = drive.kilometres * 1000 / duration

        for second in stride(from: 0.0, to: duration, by: 2) {
            travelled += metresPerSecond * 2
            // A gentle wander around Paris; enough for a coordinate stamp to look real.
            index.appendLocationSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(second),
                latitude: 48.8566 + travelled / 111_000,
                longitude: 2.3522 + travelled / 150_000,
                speed: metresPerSecond * (0.85 + 0.3 * sin(second / 37)),
                course: 90,
                altitude: 35,
                accuracy: 5
            )
        }

        for second in stride(from: 0.0, to: duration, by: 1) {
            let base = 0.05 + 0.08 * abs(sin(second / 11))
            let spike = drive.events.first { abs($0.offset - second) < 1 }?.magnitude
            index.appendMotionSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(second),
                peakG: spike ?? base
            )
        }
    }

    /// A short 1080p clip. Real frames at a real resolution: the detail screen reports the
    /// segment's dimensions, and a screenshot claiming 1080p over a 640×360 file would be
    /// a lie told in the store listing.
    private static func writeClip(to url: URL, camera: CameraPosition) async -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let size = CGSize(width: 1920, height: 1080)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
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

        let fps = 30
        let frames = 4 * fps
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = makeFrame(size: size, camera: camera, phase: Double(frame) / Double(frames)) else { break }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }

    /// A neutral moving gradient. Deliberately abstract rather than a staged road scene:
    /// an App Store screenshot should show the app's interface, not pretend to show
    /// footage the app never captured.
    private static func makeFrame(size: CGSize, camera: CameraPosition, phase: Double) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary,
            &buffer
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

        let tint = camera == .rear ? 0.16 : 0.26
        let drift = 0.04 * sin(phase * .pi * 2)
        let colours = [
            CGColor(red: tint + drift, green: tint + drift + 0.02, blue: tint + drift + 0.05, alpha: 1),
            CGColor(red: tint * 0.4, green: tint * 0.4, blue: tint * 0.5, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: size.height),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
        }
        return buffer
    }
}
