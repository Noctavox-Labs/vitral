import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a Windows icon into a macOS one.
public enum AppIcon {
    /// Slots of a macOS `.icns`: size in points and scale (1x or 2x Retina).
    static let icnsSlots: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    /// Converts a Windows `.ico` file into a macOS `.icns` file. Each slot is drawn from the
    /// closest larger image in the `.ico` (the one with more colors when there are several).
    /// Slots above the largest image are left out, since macOS scales them itself, but 128 px
    /// is always included so Finder has a good one.
    public static func icns(fromICO ico: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(ico as CFData, nil) else { return nil }
        let images = (0 ..< CGImageSourceGetCount(source))
            .compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
            .filter { $0.width > 0 && $0.width == $0.height }
            // Smallest first; at equal size, more colors first.
            .sorted { ($0.width, -$0.bitsPerPixel) < ($1.width, -$1.bitsPerPixel) }
        guard let largest = images.last else { return nil }

        let slots = icnsSlots.filter { $0.points * $0.scale <= max(128, largest.width) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.icns.identifier as CFString, slots.count, nil
        ) else { return nil }

        for slot in slots {
            let pixels = slot.points * slot.scale
            let best = images.first { $0.width >= pixels } ?? largest
            guard let image = best.width == pixels ? best : resized(best, to: pixels) else { continue }
            // 144 dpi marks the Retina (@2x) version of a size.
            let dpi = 72 * slot.scale
            let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func resized(_ image: CGImage, to side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
