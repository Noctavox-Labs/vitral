import AppKit
import VitralKit

/// A small floating window that says the program is opening. Windows programs take several
/// seconds to show their own window, and the launcher has no Dock icon, so without it nothing
/// would show that something is happening (opening the app from Finder, the Dock or Launchpad).
@MainActor
final class LoadingPanel {
    private let panel: NSPanel
    private let status: NSTextField
    private var showTask: Task<Void, Never>?

    init(name: String, icon: NSImage) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Panels hide when their app is not active, and the launcher rarely is.
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 48).isActive = true
        image.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        status = NSTextField(labelWithString: tr("Abriendo…", "Opening…"))
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let texts = NSStackView(views: [title, status])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, texts, spinner])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 20)

        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = row
            panel.contentView = glass
        } else {
            let background = NSVisualEffectView()
            background.material = .popover
            background.state = .active
            background.maskImage = Self.roundedMask(radius: 18)
            background.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                row.topAnchor.constraint(equalTo: background.topAnchor),
                row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
            panel.contentView = background
        }
    }

    /// Shows the panel after a moment, so programs that open quickly do not make it flash.
    func show(after delay: Duration = .milliseconds(700)) {
        showTask?.cancel()
        showTask = Task { [panel] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            panel.center()
            panel.orderFrontRegardless()
        }
    }

    func update(_ text: String) { status.stringValue = text }

    func close() {
        showTask?.cancel()
        panel.orderOut(nil)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
