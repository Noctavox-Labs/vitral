import AppKit
import SwiftUI
import VitralKit

@main
struct VitralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Vitral", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 560)
                .onOpenURL { model.open($0) }
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    #if DEBUG
    /// For screenshots in development: VITRAL_APPEARANCE=light or dark.
    func applicationWillFinishLaunching(_ notification: Notification) {
        switch ProcessInfo.processInfo.environment["VITRAL_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }
    #endif
}
