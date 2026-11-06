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
        let depths = storedDepths(ico)
        let images = (0 ..< CGImageSourceGetCount(source))
            .compactMap { index -> (image: CGImage, depth: Int)? in
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
                return (image, index < depths.count ? depths[index] : image.bitsPerPixel)
            }
            .filter { $0.image.width > 0 && $0.image.width == $0.image.height }
            // Smallest first; at equal size, more colors first.
            .sorted { ($0.image.width, -$0.depth) < ($1.image.width, -$1.depth) }
            .map(\.image)
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

    /// Bits per pixel of each image of an `.ico`, as stored: ImageIO hands every one back with
    /// 32 bits, so the 16-color drawing of a size looked as good as the full-color one, and came
    /// first (Encarta's icons came out dithered).
    static func storedDepths(_ ico: Data) -> [Int] {
        let bytes = [UInt8](ico)
        func u16(_ at: Int) -> Int { at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard u16(0) == 0, u16(2) == 1 else { return [] }
        return (0 ..< u16(4)).map { index in
            let entry = 6 + 16 * index, image = u32(entry + 12)
            // A PNG inside is full color; otherwise the bitmap header says (the directory's own
            // count is often 0).
            if image + 4 <= bytes.count, bytes[image ..< image + 4] == [0x89, 0x50, 0x4E, 0x47] { return 32 }
            let header = u16(image + 14)
            return header > 0 ? header : u16(entry + 6)
        }
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
