import AppKit
import SwiftUI

// Vitral's look: Liquid Glass panels over a soft stained-glass background.
// macOS 26 and newer get the system's Liquid Glass; macOS 14 and 15 get a translucent
// material with a light rim, which reads the same.

extension View {
    /// A glass panel with rounded corners.
    func vitralGlass(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        vitralGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }

    /// A glass panel in the given shape.
    @ViewBuilder
    func vitralGlass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(tint.map { $0.opacity(0.18) } ?? .clear, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
    }

    /// The main action of a screen.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// A secondary action.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Groups nearby glass shapes so they blend like one piece of glass (macOS 26+).
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// Colors of the stained glass, picked to stay calm behind text.
enum Palette {
    static let panes: [Color] = [
        Color(red: 0.16, green: 0.33, blue: 0.62),   // cobalt
        Color(red: 0.10, green: 0.50, blue: 0.52),   // teal
        Color(red: 0.80, green: 0.56, blue: 0.20),   // amber
        Color(red: 0.62, green: 0.20, blue: 0.30),   // ruby
        Color(red: 0.38, green: 0.27, blue: 0.60),   // violet
        Color(red: 0.24, green: 0.52, blue: 0.34),   // green
    ]
    static let accent = Color(red: 0.24, green: 0.45, blue: 0.85)
    /// Progress: amber, like light through stained glass. Lighter on dark glass and deeper on
    /// light glass, so the bar stands out in both (a blue bar on blue glass did not).
    static let progress = Color(nsColor: NSColor(name: "VitralProgress") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.74, blue: 0.32, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.45, blue: 0.04, alpha: 1)
    })

    /// A pane color lifted toward white, so symbols stay readable on dark glass.
    static func symbol(_ color: Color, dark: Bool) -> Color {
        guard dark, let lifted = NSColor(color).usingColorSpace(.sRGB)?.blended(withFraction: 0.35, of: .white) else {
            return color
        }
        return Color(nsColor: lifted)
    }
}

/// A low-polygon mosaic, blurred so it feels like daylight through a stained-glass window.
/// Deterministic: the same window always looks the same.
struct StainedGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var columns = 7
    var rows = 5

    var body: some View {
        Canvas { context, size in
            let points = jitteredGrid(size: size)
            var index = 0
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let a = points[row][column], b = points[row][column + 1]
                    let c = points[row + 1][column + 1], d = points[row + 1][column]
                    for triangle in [[a, b, c], [a, c, d]] {
                        var path = Path()
                        path.addLines(triangle)
                        path.closeSubpath()
                        let color = Palette.panes[(index * 7 + row * 3 + column) % Palette.panes.count]
                        let shade = 0.55 + 0.45 * noise(index)
                        context.fill(path, with: .color(color.opacity(shade)))
                        index += 1
                    }
                }
            }
        }
        .blur(radius: 46)
        .saturation(colorScheme == .dark ? 0.9 : 0.75)
        .overlay(colorScheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.48))
        .overlay(LeadLines(columns: columns, rows: rows).opacity(colorScheme == .dark ? 0.05 : 0.035))
        .background(colorScheme == .dark ? Color.black : Color.white)
        .drawingGroup()
    }

    private func jitteredGrid(size: CGSize) -> [[CGPoint]] {
        (0 ... rows).map { row in
            (0 ... columns).map { column in
                let edgeX = column == 0 || column == columns, edgeY = row == 0 || row == rows
                let dx = edgeX ? 0 : (noise(row * 31 + column) - 0.5) * 0.7
                let dy = edgeY ? 0 : (noise(row * 17 + column * 5 + 3) - 0.5) * 0.7
                return CGPoint(x: (Double(column) + dx) / Double(columns) * size.width,
                               y: (Double(row) + dy) / Double(rows) * size.height)
            }
        }
    }
}

/// The dark "lead" between panes, drawn sharp and faint over the blurred colors.
struct LeadLines: View {
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for column in 1 ..< columns {
                let x = Double(column) / Double(columns) * size.width + (noise(column) - 0.5) * 40
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + (noise(column + 9) - 0.5) * 60, y: size.height))
            }
            for row in 1 ..< rows {
                let y = Double(row) / Double(rows) * size.height + (noise(row + 20) - 0.5) * 30
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y + (noise(row + 40) - 0.5) * 50))
            }
            context.stroke(path, with: .color(.primary), lineWidth: 1)
        }
    }
}

/// Repeatable pseudo-random number in 0..<1.
func noise(_ seed: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 0x9E37_79B9)
    x ^= x >> 33
    x = x &* 0xFF51_AFD7_ED55_8CCD
    x ^= x >> 33
    return Double(x % 10_000) / 10_000
}
