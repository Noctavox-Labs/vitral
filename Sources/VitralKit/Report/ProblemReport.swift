import Foundation

/// A report to ask for help on GitHub when a program does not install, does not open or does not
/// work well. Nothing leaves the Mac by itself: the person reads it (and can change it) in Vitral,
/// and then GitHub's form opens filled in, where they decide whether to send it.
public struct ProblemReport: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The installation stopped with this message.
        case install(String)
        /// The program closed while opening, after this many attempts.
        case start(attempts: Int)
        /// The person reports it: it opens, but something does not work.
        case other
    }

    public struct Fact: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var kind: Kind
    /// Name of the program, without its version ("aTube Catcher"): what to search for.
    public var productName: String
    /// "aTube Catcher 2026.2.1"
    public var program: String
    /// "MacBookPro18,3 · Apple M1 Pro · 16 GB · macOS 27.2 · Rosetta"
    public var mac: String
    public var vitralVersion = Vitral.version
    public var facts: [Fact]
    /// Useful lines of the log, oldest first, without personal data.
    public var log: [String]
    /// The whole log, for the person to attach if they want.
    public var logFile: URL?

    public init(kind: Kind, productName: String, program: String, mac: String, facts: [Fact], log: [String], logFile: URL?) {
        self.kind = kind
        self.productName = productName
        self.program = program
        self.mac = mac
        self.facts = facts
        self.log = log
        self.logFile = logFile
    }

    public static let repository = URL(string: "https://github.com/noctavox-labs/vitral")!
    /// The form in `.github/ISSUE_TEMPLATE`; its fields are filled by their `id`.
    static let template = "app-not-working.yml"
    /// GitHub fails with longer links: 500 above about 6,500 characters when the person is not
    /// signed in (the link goes through the sign-in page), 414 above 8 KB (measured 2026-11-06).
    public static let maxURLLength = 6000

    /// The issue's title: the program and what went wrong, so reports of the same failure look alike.
    public var title: String {
        switch kind {
        case .install: return tr("\(program): no se instala", "\(program): does not install")
        case .start: return tr("\(program): se cierra al abrir", "\(program): closes while opening")
        case .other: return "\(program): "
        }
    }

    /// What happened, in words; the person adds what they saw.
    public var summary: String {
        switch kind {
        case .install(let message):
            return tr("La instalación se detuvo: \(message)", "The installation stopped: \(message)")
        case .start(let attempts):
            return attempts > 1
                ? tr("Se cerró al abrir, sin mostrar su ventana. Vitral lo intentó \(attempts) veces.",
                     "It closed while opening, without showing its window. Vitral tried \(attempts) times.")
                : tr("Se cerró al abrir, sin mostrar su ventana.", "It closed while opening, without showing its window.")
        case .other:
            return ""
        }
    }

    /// First line of the log section, to find it again in a text the person edited.
    public static var logHeading: String {
        tr("Registro (líneas útiles, sin datos personales):", "Log (useful lines, without personal data):")
    }

    /// The report as text: the facts, then the log.
    public var text: String {
        var lines = facts.map { "\($0.label): \($0.value)" }
        if !log.isEmpty {
            lines += ["", Self.logHeading] + log
        }
        return lines.joined(separator: "\n")
    }

    /// GitHub's form, filled in. `text` and `summary` are the (maybe edited) report and
    /// description; when the link would be too long, the oldest log lines go first.
    public func issueURL(text: String? = nil, summary: String? = nil) -> URL {
        func url(summary: String, report: String) -> String {
            let fields: [(String, String)] = [
                ("template", Self.template),
                ("title", title),
                ("program", program),
                ("what-happened", summary),
                ("mac", mac),
                ("vitral-version", vitralVersion),
                ("report", report),
            ]
            return Self.repository.absoluteString + "/issues/new?"
                + fields.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        // The description keeps at most half the room; the report gets the rest.
        let summary = Self.fit(summary ?? self.summary) { url(summary: $0, report: "").count <= Self.maxURLLength / 2 }
        let report = Self.fit(text ?? self.text) { url(summary: summary, report: $0).count <= Self.maxURLLength }
        return URL(string: url(summary: summary, report: report))!
    }

    /// Issues that may be about the same program.
    public var searchURL: URL {
        let query = "is:issue \"\(productName)\""
        return URL(string: Self.repository.absoluteString + "/issues?q=" + Self.encode(query))!
    }

    /// Shortens `text` until `fits`: first the oldest log lines (with a note of how many went),
    /// then, if it is still too long, the end of the text.
    static func fit(_ text: String, _ fits: (String) -> Bool) -> String {
        if fits(text) { return text }
        var lines = text.components(separatedBy: "\n")
        if let heading = lines.firstIndex(of: logHeading) {
            let logStart = heading + 1
            var removed = 0
            while lines.count > logStart + 1 {
                lines.remove(at: logStart + (removed == 0 ? 0 : 1))
                removed += 1
                let note = tr("[… \(removed) líneas más antiguas en el registro completo]",
                              "[… \(removed) older lines in the full log]")
                if removed == 1 { lines.insert(note, at: logStart) } else { lines[logStart] = note }
                if fits(lines.joined(separator: "\n")) { return lines.joined(separator: "\n") }
            }
        }
        var shortened = lines.joined(separator: "\n")
        while !shortened.isEmpty, !fits(shortened + "…") {
            shortened.removeLast(max(1, shortened.count / 20))
        }
        return shortened + "…"
    }

    /// Percent-encodes everything but letters, digits and `-._~` (a `+` would read as a space).
    static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
