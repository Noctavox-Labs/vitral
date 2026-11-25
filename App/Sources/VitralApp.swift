import AppKit
import SwiftUI
import VitralKit

@main
struct VitralApp: App {
    /// First of all, Vitral's own app object (it closes the sheets before quitting): Sparkle asks
    /// for one when `Updater` starts, and would get a plain `NSApplication`. Properties start in
    /// the order they are written.
    private let application = VitralApplication.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Vitral", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 560)
                .onOpenURL { model.open($0) }
                .onAppear {
                    (NSApp as? VitralApplication)?.mayQuit = { [model] in model.mayQuit() }
                    (NSApp as? VitralApplication)?.closeSheets = { [model] in model.closeSheets() }
                }
        }
        .defaultSize(width: 900, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Buscar actualizaciones…") { updater.checkNow() }
                    .disabled(!updater.isAvailable)
            }
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MainActor.assumeIsolated { Updater.inBackground }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened by a launcher just to update itself: no Dock icon (it also starts hidden).
        if MainActor.assumeIsolated({ Updater.inBackground }) { NSApp.setActivationPolicy(.accessory) }
        #if DEBUG
        // For screenshots in development: VITRAL_APPEARANCE=light or dark.
        switch ProcessInfo.processInfo.environment["VITRAL_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
    }

    /// The person opened Vitral while it was updating itself in the background (or Sparkle
    /// shows its question): from now on it is an ordinary Vitral.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard Updater.inBackground else { return }
            Updater.inBackground = false
            NSApp.setActivationPolicy(.regular)
        }
    }
}
