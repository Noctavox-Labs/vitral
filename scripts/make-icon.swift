// Draws Vitral's app icon: an arched stained-glass window split in four, like a window of
// Windows, with glass highlights. Writes every size of App/Resources/Assets.xcassets/AppIcon.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let panes: [CGColor] = [
    color(0.20, 0.40, 0.78), color(0.13, 0.58, 0.60), color(0.93, 0.66, 0.24),
    color(0.76, 0.24, 0.36), color(0.47, 0.33, 0.74), color(0.30, 0.62, 0.40),
    color(0.27, 0.52, 0.88), color(0.98, 0.78, 0.36),
]

func rand(_ seed: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 0x9E37_79B9)
    x ^= x >> 33; x = x &* 0xFF51_AFD7_ED55_8CCD; x ^= x >> 33
    return Double(x % 10_000) / 10_000
}

func drawIcon(side: Int) -> CGImage {
    let s = CGFloat(side) / 1024
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)

    // macOS icon tile: 824 pt square with continuous corners, centered, soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0.07, 0.09, 0.17)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [color(0.10, 0.13, 0.26), color(0.04, 0.05, 0.11)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The arched window.
    let window = CGRect(x: 262, y: 190, width: 500, height: 600)
    let radius = window.width / 2
    let arch = CGMutablePath()
    arch.move(to: CGPoint(x: window.minX, y: window.minY))
    arch.addLine(to: CGPoint(x: window.minX, y: window.maxY - radius))
    arch.addArc(center: CGPoint(x: window.midX, y: window.maxY - radius), radius: radius,
                startAngle: .pi, endAngle: 0, clockwise: true)
    arch.addLine(to: CGPoint(x: window.maxX, y: window.minY))
    arch.closeSubpath()

    // Light coming through: a warm glow behind the window.
    ctx.saveGState()
    let glow = CGGradient(colorsSpace: nil, colors: [color(1, 0.85, 0.55, 0.35), color(1, 0.85, 0.55, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(arch); ctx.clip()
    // Shards: a jittered grid of triangles, colored pane by pane.
    let columns = 6, rows = 8
    var points: [[CGPoint]] = []
    for r in 0 ... rows {
        var line: [CGPoint] = []
        for c in 0 ... columns {
            let edge = c == 0 || c == columns || r == 0 || r == rows
            let jx = edge ? 0 : (rand(r * 13 + c) - 0.5) * 0.75
            let jy = edge ? 0 : (rand(r * 29 + c * 7 + 1) - 0.5) * 0.75
            line.append(CGPoint(x: window.minX + (Double(c) + jx) / Double(columns) * window.width,
                                y: window.minY + (Double(r) + jy) / Double(rows) * window.height))
        }
        points.append(line)
    }
    var n = 0
    for r in 0 ..< rows {
        for c in 0 ..< columns {
            let a = points[r][c], b = points[r][c + 1], cc = points[r + 1][c + 1], d = points[r + 1][c]
            for tri in [[a, b, cc], [a, cc, d]] {
                let p = CGMutablePath(); p.addLines(between: tri); p.closeSubpath()
                let base = panes[(n * 5 + r * 3 + c) % panes.count]
                ctx.addPath(p); ctx.setFillColor(base); ctx.fillPath()
                // Each shard a little lighter at the top, like light through glass.
                let shine = CGGradient(colorsSpace: nil, colors: [color(1, 1, 1, 0.22 * rand(n + 100)), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
                ctx.saveGState(); ctx.addPath(p); ctx.clip()
                let box = p.boundingBox
                ctx.drawLinearGradient(shine, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
                ctx.restoreGState()
                // Lead between shards.
                ctx.addPath(p); ctx.setStrokeColor(color(0.06, 0.07, 0.12)); ctx.setLineWidth(7); ctx.setLineJoin(.round); ctx.strokePath()
                n += 1
            }
        }
    }
    ctx.restoreGState()

    // The window frame and its cross: four panes, like the window of Windows.
    // Mullions centered, so they read as four equal panes and not as a cross.
    let middle = CGPoint(x: window.midX, y: window.midY)
    for (width, stroke) in [(CGFloat(24), color(0.06, 0.07, 0.12)), (CGFloat(11), color(0.85, 0.80, 0.70))] {
        ctx.setStrokeColor(stroke); ctx.setLineCap(.butt); ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: middle.x, y: window.minY)); ctx.addLine(to: CGPoint(x: middle.x, y: window.maxY)); ctx.strokePath()
        ctx.move(to: CGPoint(x: window.minX, y: middle.y)); ctx.addLine(to: CGPoint(x: window.maxX, y: middle.y)); ctx.strokePath()
    }
    ctx.addPath(arch); ctx.setLineWidth(30); ctx.setStrokeColor(color(0.85, 0.80, 0.70)); ctx.strokePath()
    ctx.addPath(arch); ctx.setLineWidth(12); ctx.setStrokeColor(color(0.06, 0.07, 0.12)); ctx.strokePath()

    // Glass highlight across the top of the tile.
    let gloss = CGGradient(colorsSpace: nil, colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Thin rim.
    ctx.addPath(tilePath); ctx.setStrokeColor(color(1, 1, 1, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

let folder = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let rep = NSBitmapImageRep(cgImage: drawIcon(side: side))
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!
    .write(to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Ícono listo en \(folder.path)")
