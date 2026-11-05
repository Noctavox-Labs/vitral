import Foundation

/// What a wrapper app knows about its program. Saved as `Contents/Resources/vitral.json`.
public struct WrapperManifest: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public var format: Int
    public var name: String
    /// The program to open, relative to `drive_c`, with `/` separators.
    public var program: String
    public var engine: String
    public var settings: LaunchSettings
    public var recipes: [AppliedRecipe]
    public var product: VersionInfo?
    /// Name of the installer it came from.
    public var installer: String?
    public var createdWith: String
    public var created: Date

    public init(name: String, program: String, engine: String, settings: LaunchSettings,
                recipes: [AppliedRecipe] = [], product: VersionInfo? = nil, installer: String? = nil,
                createdWith: String = "Vitral \(Vitral.version)", created: Date = Date()) {
        self.format = Self.currentFormat
        self.name = name
        self.program = program
        self.engine = engine
        self.settings = settings
        self.recipes = recipes
        self.product = product
        self.installer = installer
        self.createdWith = createdWith
        self.created = created
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WrapperManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WrapperManifest.self, from: data)
    }
}

public enum WrapperError: Error, CustomStringConvertible {
    case notAWrapper(URL)
    case unsafeProgramPath(String)

    public var description: String {
        switch self {
        case .notAWrapper(let url):
            return tr("\(url.lastPathComponent) no es una app creada por Vitral.",
                      "\(url.lastPathComponent) is not an app made by Vitral.")
        case .unsafeProgramPath(let path):
            return tr("La ruta del programa no es válida: \(path)", "The program path is not valid: \(path)")
        }
    }
}

/// A Mac app that opens one Windows program:
///
///     <Name>.app/Contents/
///       Info.plist
///       MacOS/launcher                 Vitral's launcher
///       Resources/AppIcon.icns
///       Resources/vitral.json          the manifest
///       SharedSupport/prefix/          Windows (the Wine prefix) with the program installed
///
/// The Wine engine is shared, in Vitral's folder (`Components`).
public struct Wrapper: Sendable {
    public static let launcherName = "launcher"
    /// Key in Info.plist that marks apps made by Vitral.
    public static let marker = "VitralWrapper"

    public let url: URL

    public init(url: URL) { self.url = url }

    public var contents: URL { url.appendingPathComponent("Contents") }
    public var prefix: URL { contents.appendingPathComponent("SharedSupport/prefix") }
    public var manifestURL: URL { contents.appendingPathComponent("Resources/vitral.json") }
    public var launcherURL: URL { contents.appendingPathComponent("MacOS/\(Self.launcherName)") }
    public var iconURL: URL { contents.appendingPathComponent("Resources/AppIcon.icns") }

    public var isWrapper: Bool { FileManager.default.fileExists(atPath: manifestURL.path) }

    public func readManifest() throws -> WrapperManifest {
        guard isWrapper else { throw WrapperError.notAWrapper(url) }
        return try WrapperManifest.decode(Data(contentsOf: manifestURL))
    }

    /// The program's file inside the prefix. Refuses paths that would leave `drive_c`.
    public func programURL(_ manifest: WrapperManifest) throws -> URL {
        let parts = manifest.program.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !manifest.program.hasPrefix("/"),
              parts.allSatisfy({ $0 != ".." && $0 != "." }) else {
            throw WrapperError.unsafeProgramPath(manifest.program)
        }
        return parts.reduce(prefix.appendingPathComponent("drive_c")) { $0.appendingPathComponent($1) }
    }

    /// Puts `launcher` in place of the app's launcher if they differ, so apps made with an older
    /// Vitral get its fixes. Safe while the app is open: the new file takes the old one's name and
    /// the running launcher keeps the file it started from. Returns whether it changed.
    @discardableResult
    public func updateLauncher(from launcher: URL) throws -> Bool {
        guard isWrapper else { throw WrapperError.notAWrapper(url) }
        let fm = FileManager.default
        if fm.contentsEqual(atPath: launcher.path, andPath: launcherURL.path) { return false }
        let staged = launcherURL.deletingLastPathComponent().appendingPathComponent(".launcher-\(UUID().uuidString)")
        try fm.copyItem(at: launcher, to: staged)
        Self.removeQuarantine(staged)
        do {
            _ = try fm.replaceItemAt(launcherURL, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return true
    }

    /// A Vitral downloaded from the internet carries macOS's quarantine mark on its files, and a
    /// copy keeps it. The app Vitral makes is not signed as a whole (its Info.plist and icon are
    /// written here), so with the mark macOS would say it is damaged. Vitral made it on this Mac:
    /// the mark does not apply.
    static func removeQuarantine(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
        }
    }

    /// Writes everything except the prefix: launcher, icon, manifest and Info.plist.
    public func write(manifest: WrapperManifest, icns: Data?, launcher: URL, bundleIdentifier: String) throws {
        let fm = FileManager.default
        for folder in ["MacOS", "Resources", "SharedSupport"] {
            try fm.createDirectory(at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: launcherURL.path) { try fm.removeItem(at: launcherURL) }
        try fm.copyItem(at: launcher, to: launcherURL)
        Self.removeQuarantine(launcherURL)
        if let icns { try icns.write(to: iconURL) }
        try manifest.encoded().write(to: manifestURL)

        var info: [String: Any] = [
            "CFBundleDevelopmentRegion": "es",
            "CFBundleExecutable": Self.launcherName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": manifest.name,
            "CFBundleDisplayName": manifest.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": manifest.product?.productVersion ?? "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSApplicationCategoryType": "public.app-category.utilities",
            // The launcher stays in the background: the Windows program gets its own Dock icon.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            Self.marker: ["format": WrapperManifest.currentFormat, "createdWith": manifest.createdWith],
        ]
        if icns != nil { info["CFBundleIconFile"] = "AppIcon" }
        if let company = manifest.product?.companyName { info["NSHumanReadableCopyright"] = company }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A bundle identifier that is unique for each wrapper, so two copies of a program do not
    /// get mixed up by macOS.
    public static func bundleIdentifier(for name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { scalar -> Character in
            ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) ? Character(scalar) : "-"
        }
        let clean = String(slug).split(separator: "-").joined(separator: "-")
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "com.noctavox.vitral.app.\(clean.isEmpty ? "program" : clean).\(suffix)"
    }

    /// A name that works as a file name.
    public static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Programa" : String(cleaned.prefix(120))
    }
}
