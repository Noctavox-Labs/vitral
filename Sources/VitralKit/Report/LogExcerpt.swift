import Foundation

/// Removes what identifies the person from text that goes into a report: their home folder,
/// user name, full name, the Mac's name and e-mail addresses. The person still reads the report
/// before sending it; this is the first pass, not the only one.
public struct PrivateData: Sendable {
    public var home: String
    public var userName: String
    public var fullName: String
    public var computerName: String?

    public init(home: String, userName: String, fullName: String, computerName: String?) {
        self.home = home
        self.userName = userName
        self.fullName = fullName
        self.computerName = computerName
    }

    public static var current: PrivateData {
        PrivateData(home: FileManager.default.homeDirectoryForCurrentUser.path, userName: NSUserName(),
                    fullName: NSFullUserName(), computerName: Host.current().localizedName)
    }

    public func redact(_ text: String) -> String {
        var text = text
        // The home folder first, so Mac paths read "~/Downloads/…".
        let home = self.home.hasSuffix("/") ? String(self.home.dropLast()) : self.home
        if home.count > 1 { text = text.replacingOccurrences(of: home, with: "~") }
        let user = tr("<usuario>", "<user>")
        for (secret, placeholder) in [(fullName, tr("<nombre>", "<name>")), (computerName ?? "", "<Mac>"), (userName, user)] {
            // Short names would hide parts of ordinary words.
            guard secret.count >= 3 else { continue }
            text = Self.replaceWord(secret, with: placeholder, in: text)
        }
        text = text.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                                         with: tr("<correo>", "<e-mail>"), options: .regularExpression)
        return text
    }

    /// Replaces `word` (any case) where it is not part of a longer word.
    static func replaceWord(_ word: String, with replacement: String, in text: String) -> String {
        let pattern = #"(?i)(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![A-Za-z0-9])"#
        return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: replacement),
                                         options: .regularExpression)
    }
}

/// The lines of a Wine log that help find why a program failed: Vitral's own lines, Wine's
/// errors and what the program printed, without Wine's notes (`fixme`, `warn`, `info`), known
/// harmless lines, or repeats (vMix's log has the same COM error 33,000 times).
public enum LogExcerpt {
    /// Lines Wine prints for every program, which never explain a failure: the catalog's harmless
    /// entries.
    static func harmlessPatterns(_ catalog: FailureCatalog) -> [NSRegularExpression] {
        catalog.harmless.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Reads a log; for a large one, its beginning and its end (where the failure usually is).
    public static func read(_ url: URL, head: Int = 256 * 1024, tail: Int = 1024 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(head + tail) else {
            return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        }
        let start = String(decoding: (try? handle.read(upToCount: head)) ?? Data(), as: UTF8.self)
        try? handle.seek(toOffset: size - UInt64(tail))
        let end = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        // Cut both at whole lines.
        let startLines = start.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let endLines = end.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        return (startLines + ["…"] + endLines).joined(separator: "\n")
    }

    /// The useful lines, oldest first, at most `limit`. A line seen several times appears once,
    /// where it was first seen, with how many times: "(×33102)".
    public static func lines(of text: String, limit: Int = 60, catalog: FailureCatalog = .builtIn) -> [String] {
        struct Entry { var line: String; var count: Int; let priority: Int }
        let harmless = harmlessPatterns(catalog)
        var entries: [Entry] = []
        var index: [String: Int] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "…", let priority = priority(of: line, harmless: harmless) else { continue }
            // Vitral's own lines tell the story of each attempt: never merged.
            let key = line.hasPrefix("[Vitral") ? "\(entries.count)" : Self.key(of: line)
            if let existing = index[key] {
                entries[existing].count += 1
            } else {
                index[key] = entries.count
                entries.append(Entry(line: String(line.prefix(300)), count: 1, priority: priority))
            }
        }
        // Over the limit: the most telling first and, among the same kind, the latest.
        var kept = Set(entries.indices)
        if entries.count > limit {
            let ranked = entries.indices.sorted { (entries[$0].priority, -$0) < (entries[$1].priority, -$1) }
            kept = Set(ranked.prefix(limit))
        }
        return entries.indices.filter(kept.contains).map { i in
            entries[i].count > 1 ? "\(entries[i].line) (×\(entries[i].count))" : entries[i].line
        }
    }

    /// 0: says what failed; 1: an error; 2: anything else the program printed; nil: not useful.
    static func priority(of line: String, harmless: [NSRegularExpression] = []) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if harmless.contains(where: { $0.firstMatch(in: line, range: range) != nil }) { return nil }
        let body = withoutThread(line)
        // What a program said in a message box (`WineMessageBox`).
        if body.hasPrefix(WineMessageBox.marker) { return 0 }
        if body.hasPrefix("fixme:") || body.hasPrefix("trace:") || body.hasPrefix("warn:") || body.hasPrefix("info:") { return nil }
        if line.hasPrefix("[Vitral") || line.contains("Unhandled") || body.hasPrefix("err:module") || body.hasPrefix("err:seh")
            || line.hasPrefix("wine:") || line.localizedCaseInsensitiveContains("exception") { return 0 }
        if body.hasPrefix("err:") || line.contains("ERROR") || line.contains("FATAL")
            || line.localizedCaseInsensitiveContains("[critical]") || line.localizedCaseInsensitiveContains("[error]") { return 1 }
        return 2
    }

    /// Wine's lines begin with the thread number ("0024:err:…").
    static func withoutThread(_ line: String) -> String {
        line.replacing(#/^[0-9a-f]{4}:/#, with: "", maxReplacements: 1)
    }

    /// The line with what changes between repeats (thread, addresses, numbers) taken out.
    static func key(of line: String) -> String {
        withoutThread(line)
            .replacing(#/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#, with: "#")
            .replacing(#/0x[0-9A-Fa-f]+|[0-9]+/#, with: "#")
    }
}
