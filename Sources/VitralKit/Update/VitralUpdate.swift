import Foundation

/// Keeps Vitral and the launchers inside the apps up to date when the person only opens their
/// programs and never Vitral (Javier, 2026-11-06). Vitral updates itself with Sparkle only while
/// it runs, and it gives the apps its launcher only when it opens; a newer engine and new fixes
/// come with the launcher. So the launcher does two things when a program opens:
///
/// - If the Vitral on this Mac is newer than itself, it puts that Vitral's launcher in its app
///   and opens the app again with it.
/// - At most once a day, if the person lets Vitral look for updates by itself, it reads Sparkle's
///   feed; if there is a newer Vitral, it opens Vitral without a window to update itself
///   (`backgroundArgument`). The next opening of the program then gets its launcher.
public enum VitralUpdate {
    public static let bundleIdentifier = "com.noctavox.vitral"
    /// Sparkle's feed (`SUFeedURL`); `VITRAL_APPCAST` replaces it to test.
    public static var appcast: URL {
        if let custom = ProcessInfo.processInfo.environment["VITRAL_APPCAST"], let url = URL(string: custom) { return url }
        return URL(string: "https://github.com/noctavox-labs/vitral/releases/latest/download/appcast.xml")!
    }
    /// How Vitral is opened just to update itself: no window, and it quits when done.
    public static let backgroundArgument = "--update-in-background"
    /// Set in the environment of a launcher opened again after taking a newer one, with the
    /// version it came from: it is never replaced twice in a row.
    public static let updatedVariable = "VITRAL_UPDATED_LAUNCHER"

    /// Whether version `a` is newer than `b` (0.1.10 is newer than 0.1.9).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// The newest version a Sparkle feed offers (`sparkle:shortVersionString`, as an element or
    /// as an attribute of the enclosure).
    public static func latestVersion(inAppcast data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let pattern = try? NSRegularExpression(pattern: #"sparkle:shortVersionString\s*(?:>|=\s*")\s*([0-9][0-9A-Za-z.\-]*)"#) else { return nil }
        let versions = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        return versions.max { isNewer($1, than: $0) }
    }

    /// The version of an app (`CFBundleShortVersionString`), read from disk each time: `Bundle`
    /// keeps what it read, and the app may have been updated meanwhile.
    public static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// The Vitral installed on this Mac, from the copies macOS knows of (it remembers every
    /// copy it saw: the one in Applications, the one in the disk image it came in, an old one
    /// in Downloads): the newest version, not counting copies in the Trash or on a read-only
    /// disk (a disk image, which Sparkle cannot update). On equal versions, Applications first.
    public static func installed(among copies: [URL]) -> URL? {
        let fm = FileManager.default
        let candidates = copies.compactMap { url -> (url: URL, version: String)? in
            let url = url.standardizedFileURL
            guard fm.fileExists(atPath: url.path), !url.pathComponents.contains(".Trash"),
                  (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true,
                  let version = version(of: url) else { return nil }
            return (url, version)
        }
        func inApplications(_ url: URL) -> Bool { url.deletingLastPathComponent().lastPathComponent == "Applications" }
        return candidates.max { a, b in
            if a.version != b.version { return isNewer(b.version, than: a.version) }
            if inApplications(a.url) != inApplications(b.url) { return inApplications(b.url) }
            return a.url.path > b.url.path
        }?.url
    }

    /// The launcher a Vitral.app carries for the apps it makes.
    public static func launcher(in vitral: URL) -> URL? {
        let url = vitral.appendingPathComponent("Contents/MacOS/vitral-launcher")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// When a launcher last read the feed: the date of a file in Vitral's folder.
    static func stamp(in home: VitralHome) -> URL { home.url.appendingPathComponent("Updates/last-check") }

    /// Whether a day (or `interval`) went by since a launcher last read the feed.
    public static func isDue(home: VitralHome = .default, every interval: TimeInterval = 86_400, now: Date = Date()) -> Bool {
        guard let last = try? stamp(in: home).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return true }
        return now.timeIntervalSince(last) > interval || last > now
    }

    /// Notes that a launcher read the feed now (also when it could not: no need to insist).
    public static func markChecked(home: VitralHome = .default, now: Date = Date()) {
        let file = stamp(in: home)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    /// The newest Vitral in the feed, if it is newer than `installed`.
    public static func newerVersion(than installed: String, timeout: TimeInterval = 10) async throws -> String? {
        let request = URLRequest(url: appcast, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ComponentError.downloadFailed("\(appcast.absoluteString): HTTP \(http.statusCode)")
        }
        guard let latest = latestVersion(inAppcast: data), isNewer(latest, than: installed) else { return nil }
        return latest
    }
}
