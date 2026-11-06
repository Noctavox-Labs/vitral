import Foundation

/// A message box a Windows program showed, read from Wine's log. Vitral turns on Wine's `msgbox`
/// channel (`InstalledEngine.environment`), which writes each box's text as it opens; Vitral's
/// engine also writes its caption and style (`engine-patches/0008`):
///
///     0104:trace:msgbox:MSGBOX_OnInit L"Application cannot start." caption L"Encarta" style 0x30
///
/// Reading the log needs no Screen Recording permission, which window titles do.
public struct WineMessageBox: Hashable, Sendable {
    public enum Icon: Sendable {
        case error, question, warning, information, none
    }

    public let text: String
    public let caption: String?
    /// The `MB_…` style. Nil from engines that only write the text.
    public let style: UInt32?
    /// Wine writes about 290 characters of each text at most.
    public let truncated: Bool

    public init(text: String, caption: String? = nil, style: UInt32? = nil, truncated: Bool = false) {
        self.text = text
        self.caption = caption
        self.style = style
        self.truncated = truncated
    }

    public var icon: Icon? {
        style.map { style in
            switch style & 0xF0 {
            case 0x10: .error
            case 0x20: .question
            case 0x30: .warning
            case 0x40: .information
            default: .none
            }
        }
    }

    /// Whether it can be an error: anything but a question or a notice. Programs made with MFC
    /// show their errors with the warning icon, and some with none; engines that do not write the
    /// style give no way to tell.
    public var isError: Bool {
        guard let icon else { return true }
        return icon != .question && icon != .information
    }

    /// The text on one line, after its caption: "Microsoft Encarta: Application cannot start."
    public var summary: String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ") + (truncated ? "…" : "")
        guard let caption, !caption.isEmpty else { return line }
        return caption + ": " + line
    }

    /// Every box in a log, in order.
    public static func all(in log: String) -> [WineMessageBox] {
        guard log.contains(marker) else { return [] }
        return log.split(separator: "\n").compactMap { line in
            guard let at = line.range(of: marker) else { return nil }
            return parse(line[at.upperBound...])
        }
    }

    static let marker = "trace:msgbox:"

    /// `MSGBOX_OnInit L"…"`, then `caption L"…"` and `style 0x…` from Vitral's engine.
    static func parse(_ line: Substring) -> WineMessageBox? {
        guard let open = line.range(of: #"L""#), let (text, truncated, afterText) = string(line[open.lowerBound...]) else { return nil }
        var rest = afterText
        var caption: String?
        var style: UInt32?
        if rest.hasPrefix(" caption "), let (value, _, after) = string(rest.dropFirst(" caption ".count)) {
            caption = value
            rest = after
        }
        if rest.hasPrefix(" style ") {
            let number = rest.dropFirst(" style ".count).prefix { $0.isHexDigit || $0 == "x" }
            style = UInt32(number.hasPrefix("0x") ? number.dropFirst(2) : number, radix: 16)
        }
        return WineMessageBox(text: text, caption: caption, style: style, truncated: truncated)
    }

    /// A string as Wine's `debugstr_w` writes it: `L"…"`, with `\n`, `\r`, `\t`, `\"`, `\\` and
    /// `\XXXX` (a UTF-16 unit in hex) for everything outside printable ASCII, and `...` after it
    /// when it was cut. With what follows it.
    static func string(_ text: Substring) -> (String, truncated: Bool, rest: Substring)? {
        let scalars = text.unicodeScalars
        guard text.hasPrefix(#"L""#) else { return nil }
        var index = scalars.index(scalars.startIndex, offsetBy: 2)
        var units: [UInt16] = []
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\"" {
                var rest = Substring(scalars[scalars.index(after: index)...])
                let truncated = rest.hasPrefix("...")
                if truncated { rest = rest.dropFirst(3) }
                return (String(decoding: units, as: UTF16.self), truncated, rest)
            }
            guard scalar == "\\" else {
                units.append(contentsOf: String(scalar).utf16)
                index = scalars.index(after: index)
                continue
            }
            let next = scalars.index(after: index)
            guard next < scalars.endIndex else { return nil }
            let simple: [Unicode.Scalar: UInt16] = ["n": 10, "r": 13, "t": 9, "\"": 34, "\\": 92]
            if let unit = simple[scalars[next]] {
                units.append(unit)
                index = scalars.index(after: next)
            } else {
                var hex = ""
                guard let end = scalars.index(next, offsetBy: 4, limitedBy: scalars.endIndex) else { return nil }
                hex.unicodeScalars.append(contentsOf: scalars[next..<end])
                guard let unit = UInt16(hex, radix: 16) else { return nil }
                units.append(unit)
                index = end
            }
        }
        return nil
    }
}

/// Tells the program's own windows from the error boxes it shows while starting, and whether it
/// closed on one. Each error box Wine writes to the log goes with a new window of the program, the
/// smallest first; a new normal window left over is the program's. Boxes that stay on top (system
/// modal) are above the normal layer, so windows of every layer count. A box that no window of the
/// program takes within a few seconds was another process's, and is dropped.
public struct StartupBoxes: Sendable {
    /// Error boxes the program showed, in order.
    public private(set) var shown: [WineMessageBox] = []
    /// When the first one showed, and when one was last on screen.
    public private(set) var firstShown: Date?
    public private(set) var lastShowing: Date?
    private var known: Set<Int> = []
    private var boxWindows: Set<Int> = []
    private var waiting: [(box: WineMessageBox, since: Date)] = []
    static let patience: TimeInterval = 3
    /// A program that closes this soon after its error box goes closed because of it: the person
    /// pressed OK and that was the end.
    public static let grace: TimeInterval = 5

    public init() {}

    /// Adds the boxes Wine wrote since the last look and the program's windows on screen now. The
    /// first new window that is the program's own, if one appeared; and the boxes that appeared.
    public mutating func look(at windows: [WineWindows.Window], newBoxes: [WineMessageBox],
                              now: Date = Date()) -> (window: WineWindows.Window?, boxes: [(WineMessageBox, WineWindows.Window)]) {
        waiting += newBoxes.filter(\.isError).map { ($0, now) }
        waiting.removeAll { now.timeIntervalSince($0.since) > Self.patience }
        var own: WineWindows.Window?
        var appeared: [(WineMessageBox, WineWindows.Window)] = []
        for window in windows.filter({ !known.contains($0.number) }).sorted(by: { $0.area < $1.area }) {
            known.insert(window.number)
            if !waiting.isEmpty {
                let box = waiting.removeFirst().box
                boxWindows.insert(window.number)
                shown.append(box)
                appeared.append((box, window))
                if firstShown == nil { firstShown = now }
            } else if window.layer == 0, own == nil {
                own = window
            }
        }
        if !waiting.isEmpty || windows.contains(where: { boxWindows.contains($0.number) }) { lastShowing = now }
        return (own, appeared)
    }

    /// Whether an error box is on screen, about to show, or went a moment ago.
    public func busy(now: Date = Date()) -> Bool {
        !waiting.isEmpty || lastShowing.map { now.timeIntervalSince($0) <= Self.grace } == true
    }

    /// Whether the program, ending at `end`, closed on an error box while starting: it showed only
    /// error boxes; or one showed in its first seconds (after a splash screen, as Encarta 2009's
    /// "Application cannot start") and it closed while it was on screen or right after.
    public func closedOnBox(started: Date, opened: Bool, end: Date = Date()) -> Bool {
        guard let firstShown else { return false }
        if !opened { return true }
        return firstShown.timeIntervalSince(started) < StartupWatch.startupWindow
            && lastShowing.map { end.timeIntervalSince($0) <= Self.grace } == true
    }
}
