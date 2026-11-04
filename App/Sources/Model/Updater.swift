import Foundation
import Observation
import Sparkle

/// Automatic updates with Sparkle: checks GitHub Releases, downloads the new version,
/// verifies its EdDSA signature and installs it in place, without a browser.
///
/// Sparkle only starts once the release key (`SUPublicEDKey`) is in Info.plist; until the
/// first signed release, builds from source simply do not update themselves.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).map { !$0.isEmpty } ?? false
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
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
