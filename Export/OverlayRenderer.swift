import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit

/// One line of burned-in information, valid for a slice of the exported timeline.
struct OverlayStamp: Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let text: String
}

/// Builds the Core Animation layer tree that stamps date / time / position / speed onto
/// an exported file.
///
/// The stored recordings are never touched. Everything here runs at export time and only
/// when the user picks "Export with information" — the file on disk stays an untouched
/// original, which is exactly what makes it useful as evidence.
enum OverlayRenderer {
    /// Bottom-left, as specified. Inset in points of the render size.
    static let inset = CGPoint(x: 28, y: 28)

    /// Turns the metadata of a session into one stamp per time slice.
    ///
    /// The slice length adapts to the export length so a three-hour drive does not
    /// produce a hundred thousand layers: at most `maximumStamps` are ever built.
    static func stamps(
        start: Date,
        duration: TimeInterval,
        fields: OverlayFields,
        speedProvider: (Date) -> Double?,
        coordinateProvider: (Date) -> (latitude: Double, longitude: Double)?,
        maximumStamps: Int = 1200
    ) -> [OverlayStamp] {
        guard duration > 0, !fields.isEmpty else { return [] }
        let step = max(1.0, (duration / Double(maximumStamps)).rounded(.up))
        var result: [OverlayStamp] = []
        var offset: TimeInterval = 0

        while offset < duration {
            let date = start.addingTimeInterval(offset)
            var parts: [String] = []

            let stamp = Format.overlayStamp(date, fields: fields)
            if !stamp.isEmpty { parts.append(stamp) }

            if fields.contains(.speed), let speed = speedProvider(date) {
                parts.append(Format.speed(kilometresPerHour: speed))
            }
            if fields.contains(.location), let coordinate = coordinateProvider(date) {
                parts.append(Format.coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }

            if !parts.isEmpty {
                result.append(OverlayStamp(
                    start: offset,
                    duration: min(step, duration - offset),
                    text: parts.joined(separator: "   ")
                ))
            }
            offset += step
        }
        return result
    }

    /// The mark in the opposite corner from the data: smaller, quieter, and visible for
    /// the whole file rather than a slice of it.
    ///
    /// Deliberately discreet. A watermark across the middle of the frame would obscure the
    /// very thing the recording exists to show — and it would be the first reason someone
    /// re-encodes the file to get rid of it, taking the mark with them.
    static func signatureLayer(text: String, renderSize: CGSize, fontSize: CGFloat) -> CATextLayer {
        let size = fontSize * 0.78
        let layer = CATextLayer()
        layer.string = text
        layer.font = UIFont.systemFont(ofSize: size, weight: .semibold)
        layer.fontSize = size
        layer.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        layer.alignmentMode = .right
        layer.contentsScale = 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.9
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        layer.name = signatureLayerName
        layer.frame = CGRect(
            x: renderSize.width - inset.x - size * 20,
            y: renderSize.height - inset.y - size * 1.4,
            width: size * 20,
            height: size * 1.4
        )
        return layer
    }

    /// Named so a test can find it in the tree rather than assert on a screenshot.
    static let signatureLayerName = "dashcam.signature"

    /// Assembles the parent/video layer pair an `AVVideoCompositionCoreAnimationTool`
    /// needs, with every stamp scheduled on the export timeline.
    static func makeAnimationTool(
        renderSize: CGSize,
        stamps: [OverlayStamp],
        signature: String? = nil
    ) -> (tool: AVVideoCompositionCoreAnimationTool, parent: CALayer)? {
        // A signature alone is reason enough to build the tree: someone who turned every
        // measurement off may still want the file to say where it came from.
        guard !stamps.isEmpty || signature != nil else { return nil }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        // Scale the type with the frame so a 720p and a 1080p export look the same.
        let fontSize = max(16, renderSize.height * 0.032)
        let barHeight = fontSize * 1.9
        let barWidth = renderSize.width - inset.x * 2

        if !stamps.isEmpty {
            let background = CALayer()
            background.frame = CGRect(x: inset.x, y: inset.y, width: barWidth, height: barHeight)
            background.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
            background.cornerRadius = barHeight / 4
            parentLayer.addSublayer(background)
        }

        if let signature {
            parentLayer.addSublayer(signatureLayer(text: signature, renderSize: renderSize, fontSize: fontSize))
        }

        for stamp in stamps {
            let textLayer = CATextLayer()
            textLayer.string = stamp.text
            textLayer.font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            textLayer.fontSize = fontSize
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.alignmentMode = .left
            textLayer.contentsScale = 2
            textLayer.shadowColor = UIColor.black.cgColor
            textLayer.shadowOpacity = 0.9
            textLayer.shadowRadius = 2
            textLayer.shadowOffset = .zero
            textLayer.frame = CGRect(
                x: inset.x + fontSize * 0.6,
                y: inset.y + (barHeight - fontSize * 1.2) / 2,
                width: barWidth - fontSize * 1.2,
                height: fontSize * 1.25
            )
            // Hidden by default; the keyframe animation reveals it for its own slice only.
            textLayer.opacity = 0

            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 1, 1, 0]
            animation.keyTimes = [0, 0.0001, 0.9999, 1]
            animation.beginTime = stamp.start == 0 ? AVCoreAnimationBeginTimeAtZero : stamp.start
            animation.duration = stamp.duration
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            textLayer.add(animation, forKey: "reveal")

            parentLayer.addSublayer(textLayer)
        }

        let tool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )
        return (tool, parentLayer)
    }
}
