// Builds the app icon from Roland's: the dark background turns slate grey, so the port stands apart from the original.
//
//   swift packaging/make-icon.swift <Roland's AppIcon.icns> <output.icns>
//
// Every image in the source is recoloured and written back with its own properties, so the sizes stay Roland's.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let originalBackground: [Double] = [36, 36, 36]
let newBackground: [Double] = [92, 99, 112]
/// How far from the background a pixel may be and still shift (anti-aliased edges shift partly).
let tolerance = 48.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Shifts the pixels of 8-bit RGBA with straight (un-premultiplied) alpha, the layout ImageIO decodes Roland's PNGs to.
func recoloured(_ image: CGImage) -> CGImage? {
    guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
        image.bitmapInfo == CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        let space = image.colorSpace, let source = image.dataProvider?.data
    else { return nil }
    var pixels = Data(referencing: source)
    pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for row in 0..<image.height {
            for column in 0..<image.width {
                let start = row * image.bytesPerRow + column * 4
                let distance = (0..<3).map { abs(Double(bytes[start + $0]) - originalBackground[$0]) }.max() ?? 0
                let weight = max(0, 1 - distance / tolerance)
                for channel in 0..<3 {
                    let shift = weight * (newBackground[channel] - originalBackground[channel])
                    let shifted = Double(bytes[start + channel]) + shift
                    // Half to even, as Python's round() did in 0.1.1's icon script.
                    bytes[start + channel] = UInt8(min(255, shifted.rounded(.toNearestOrEven)))
                }
            }
        }
    }
    guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
    return CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let input = arguments.first, let output = arguments.last else {
    fail("usage: swift packaging/make-icon.swift <Roland's AppIcon.icns> <output.icns>")
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
    CGImageSourceGetCount(source) > 0
else { fail("Cannot read icon images from \(input)") }
guard
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: output) as CFURL, UTType.icns.identifier as CFString, CGImageSourceGetCount(source), nil)
else { fail("Cannot write \(output)") }

for index in 0..<CGImageSourceGetCount(source) {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), let shifted = recoloured(image) else {
        fail("Image \(index) of \(input) is not 8-bit RGBA with straight alpha")
    }
    CGImageDestinationAddImage(destination, shifted, CGImageSourceCopyPropertiesAtIndex(source, index, nil))
}
guard CGImageDestinationFinalize(destination) else { fail("Cannot write \(output)") }
