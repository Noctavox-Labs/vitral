import AppKit

/// Vitral's `NSApplication`. AppKit refuses to quit while a window has a sheet (the analysis, the
/// setup assistant), without asking the delegate: ⌘Q, Quit in the Dock, AppleScript and logging
/// out did nothing, and Sparkle could not restart Vitral to update it. Here the sheets are closed
/// first, and Vitral quits once they are gone. During an installation, `mayQuit` asks.
@objc(VitralApplication)
final class VitralApplication: NSApplication {
    /// Whether Vitral may quit now. False when it will quit by itself later (once an installation
    /// is cancelled) or should not quit.
    var mayQuit: () -> Bool = { true }
    /// Closes the app's sheets the SwiftUI way, through the state that shows them: AppKit's
    /// `endSheet` does not close a SwiftUI sheet.
    var closeSheets: () -> Void = {}
    /// Set while the sheets close on their way out (they leave with an animation).
    private var closingSheets = false
    private var waits = 0

    override func finishLaunching() {
        super.finishLaunching()
        // Quit from the Dock, AppleScript or logging out: AppKit's own handler refuses with a
        // sheet open before it gets to `terminate(_:)`.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(quitEvent(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func quitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        terminate(nil)
        // Still here and not on its way out: the person chose to keep installing (or Vitral quits
        // when the cancelled installation is cleaned up). Logging out stops, as with any app that says no.
        if !closingSheets {
            reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
        }
    }

    override func terminate(_ sender: Any?) {
        guard closingSheets || mayQuit() else { return }
        // The innermost first: a sheet can have its own (the report, over the analysis).
        let sheets = windows.compactMap(\.attachedSheet).filter { $0.attachedSheet == nil }
        // A sheet that does not leave in 3 s: AppKit says no, as before.
        guard sheets.isEmpty || waits >= 30 else {
            if !closingSheets { closeSheets() }
            closingSheets = true
            waits += 1
            // AppKit's own (the open panel).
            for sheet in sheets { sheet.sheetParent?.endSheet(sheet) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.terminate(sender) }
            return
        }
        closingSheets = false
        waits = 0
        super.terminate(sender)
    }
}
