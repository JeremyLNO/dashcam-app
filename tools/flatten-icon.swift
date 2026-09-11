import AppKit
import CoreGraphics
import Foundation

// Prepares an App Store icon from artwork that has a transparent margin.
//
// Two things have to be true for App Store Connect to accept it (ITMS-90717): no alpha
// channel, and 1024x1024. Naively flattening leaves the transparent margin as a coloured
// border around the artwork's own rounded corners — and iOS then masks its own corners on
// top, so the result looks inset and wrong. So: crop to the opaque bounds first, then
// scale that to fill the square, then flatten.
let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let source = NSImage(contentsOfFile: inputPath),
      let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot read \(inputPath)") }

let width = cgImage.width
let height = cgImage.height

// Read the alpha channel to find the artwork's real bounds.
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let readContext = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }
readContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        // Anything close to fully transparent is margin, not artwork: the edge of a
        // rounded shape is antialiased, so a strict > 0 test would keep a halo.
        if pixels[(y * width + x) * 4 + 3] > 24 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else { fatalError("image is fully transparent") }

// Square the crop around the artwork's centre so nothing is stretched.
let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1
let side = max(cropWidth, cropHeight)
let centreX = (minX + maxX) / 2
let centreY = (minY + maxY) / 2
let originX = max(0, min(width - side, centreX - side / 2))
let originY = max(0, min(height - side, centreY - side / 2))
let cropRect = CGRect(x: originX, y: originY, width: side, height: side)
guard let cropped = cgImage.cropping(to: cropRect) else { fatalError("crop") }

// Background colour taken from a pixel just inside the artwork, so any residual edge
// blends instead of showing a white rim.
let sampleX = min(width - 1, minX + cropWidth / 2)
let sampleY = min(height - 1, minY + 6)
let sampleOffset = (sampleY * width + sampleX) * 4
let background = CGColor(
    red: CGFloat(pixels[sampleOffset]) / 255,
    green: CGFloat(pixels[sampleOffset + 1]) / 255,
    blue: CGFloat(pixels[sampleOffset + 2]) / 255,
    alpha: 1
)

let target = 1024
guard let output = CGContext(
    data: nil, width: target, height: target, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("output context") }

output.interpolationQuality = .high
output.setFillColor(background)
output.fill(CGRect(x: 0, y: 0, width: target, height: target))
output.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))

guard let result = output.makeImage() else { fatalError("render") }
let rep = NSBitmapImageRep(cgImage: result)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try data.write(to: URL(fileURLWithPath: outputPath))
print("cropped \(cropRect) from \(width)x\(height) -> \(target)x\(target), opaque")
