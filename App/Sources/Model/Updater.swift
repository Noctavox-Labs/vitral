import AppKit
import Foundation
import Observation
import Sparkle
import VitralKit

/// Automatic updates with Sparkle: checks GitHub Releases, downloads the new version,
/// verifies its EdDSA signature and installs it in place, without a browser.
///
/// Sparkle only starts once the release key (`SUPublicEDKey`) is in Info.plist; until the
/// first signed release, builds from source simply do not update themselves.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = UpdaterDelegate()

    /// Opened by an app's launcher just to update itself (`VitralUpdate.backgroundArgument`):
    /// no window and no Dock icon, and it quits when Sparkle is done. It ends if the person
    /// opens Vitral meanwhile (`AppDelegate`).
    static var inBackground = CommandLine.arguments.contains(VitralUpdate.backgroundArgument)

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).map { !$0.isEmpty } ?? false
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
            : nil
        guard Self.inBackground else { return }
        let updater = controller?.updater
        Task {
            guard let updater else { return Updater.quitIfInBackground() }
            // Starting, Sparkle looks for an update left half installed, and a check asked for
            // meanwhile is dropped ("session in progress"): it waits until Sparkle is free.
            for _ in 0 ..< 120 where updater.sessionInProgress || !updater.canCheckForUpdates {
                try? await Task.sleep(for: .milliseconds(250))
            }
            updater.checkForUpdatesInBackground()
            // In case Sparkle never says it is done.
            try? await Task.sleep(for: .seconds(900))
            Updater.quitIfInBackground()
        }
    }

    static func quitIfInBackground() {
        if inBackground { NSApp.terminate(nil) }
    }

    var isAvailable: Bool { controller != nil }

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller?.updater.automaticallyChecksForUpdates ?? true }
        set {
            withMutation(keyPath: \.checksAutomatically) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return controller?.updater.automaticallyDownloadsUpdates ?? true }
        set {
            withMutation(keyPath: \.installsAutomatically) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkNow() { controller?.checkForUpdates(nil) }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Sparkle's questions, answered for a Vitral opened just to update itself.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Without a window, an update downloaded by itself is installed now rather than when
    /// Vitral quits (Sparkle's way when the person has Vitral open).
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard MainActor.assumeIsolated({ Updater.inBackground }) else { return false }
        immediateInstallHandler()
        return true
    }

    /// The new Vitral does not open by itself: nobody asked to see it.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        !MainActor.assumeIsolated { Updater.inBackground }
    }

    /// Sparkle is done. Quitting installs the update it downloaded by itself, if there is one
    /// (0.1.5 → 0.1.6, found, downloaded and installed in about 10 s, 2026-11-06); otherwise there
    /// was none, no connection, or the person said "later".
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { Updater.quitIfInBackground() }
    }
}
