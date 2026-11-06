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
    /// SHA-256 of that installer, to tell versions apart in reports (since Vitral 0.1.6).
    public var installerSHA256: String?
    /// Folder of the app's Windows (Wine prefix) in Vitral's `Prefixes` folder. Nil in apps made
    /// before Vitral 0.1.1, which keep it inside the app until Vitral moves it out.
    public var prefix: String?
    public var createdWith: String
    public var created: Date

    public init(name: String, program: String, engine: String, settings: LaunchSettings,
                recipes: [AppliedRecipe] = [], product: VersionInfo? = nil, installer: String? = nil,
                installerSHA256: String? = nil, prefix: String? = nil,
                createdWith: String = "Vitral \(Vitral.version)", created: Date = Date()) {
        self.format = Self.currentFormat
        self.name = name
        self.program = program
        self.engine = engine
        self.settings = settings
        self.recipes = recipes
        self.product = product
        self.installer = installer
        self.installerSHA256 = installerSHA256
        self.prefix = prefix
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
    case signingFailed(String)
    case prefixInTheWay(URL)

    public var description: String {
        switch self {
        case .notAWrapper(let url):
            return tr("\(url.lastPathComponent) no es una app creada por Vitral.",
                      "\(url.lastPathComponent) is not an app made by Vitral.")
        case .unsafeProgramPath(let path):
            return tr("La ruta del programa no es válida: \(path)", "The program path is not valid: \(path)")
        case .signingFailed(let detail):
            return tr("No se pudo firmar la app: \(detail)", "Could not sign the app: \(detail)")
        case .prefixInTheWay(let url):
            return tr("Ya hay una carpeta en \(url.path).", "There is already a folder at \(url.path).")
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
///
/// Windows (the Wine prefix) with the program installed lives in Vitral's folder
/// (`Prefixes/<manifest.prefix>`), like the shared Wine engine (`Components`). It used to live
/// inside the app (`SharedSupport/prefix`, before 0.1.1), but macOS only opens apps whose
/// signature seals everything inside, and a prefix links to the person's folders and changes each
/// time the program runs. The app itself is small and signed ad hoc when Vitral writes it.
public struct Wrapper: Sendable {
    public static let launcherName = "launcher"
    /// Key in Info.plist that marks apps made by Vitral.
    public static let marker = "VitralWrapper"

    public let url: URL

    public init(url: URL) { self.url = url }

    public var contents: URL { url.appendingPathComponent("Contents") }
    /// Where apps made before Vitral 0.1.1 keep their prefix.
    public var embeddedPrefix: URL { contents.appendingPathComponent("SharedSupport/prefix") }

    /// The app's Windows (Wine prefix).
    public func prefix(in home: VitralHome) -> URL {
        if let name = (try? readManifest())?.prefix, Self.isFolderName(name) {
            return home.prefixes.appendingPathComponent(name)
        }
        return embeddedPrefix
    }

    public var prefix: URL { prefix(in: .default) }

    /// A plain folder name: no separators, not "." or "..".
    static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
    public var manifestURL: URL { contents.appendingPathComponent("Resources/vitral.json") }
    public var launcherURL: URL { contents.appendingPathComponent("MacOS/\(Self.launcherName)") }
    public var iconURL: URL { contents.appendingPathComponent("Resources/AppIcon.icns") }

    public var isWrapper: Bool { FileManager.default.fileExists(atPath: manifestURL.path) }

    public func readManifest() throws -> WrapperManifest {
        guard isWrapper else { throw WrapperError.notAWrapper(url) }
        return try WrapperManifest.decode(Data(contentsOf: manifestURL))
    }

    /// The program's file inside the prefix. Refuses paths that would leave `drive_c`.
    public func programURL(_ manifest: WrapperManifest, prefix: URL? = nil) throws -> URL {
        let parts = manifest.program.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !manifest.program.hasPrefix("/"),
              parts.allSatisfy({ $0 != ".." && $0 != "." }) else {
            throw WrapperError.unsafeProgramPath(manifest.program)
        }
        return parts.reduce((prefix ?? self.prefix).appendingPathComponent("drive_c")) { $0.appendingPathComponent($1) }
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
        // A prefix still inside the app cannot be sealed: the app is signed once it moves out.
        if !fm.fileExists(atPath: embeddedPrefix.path) { try sign() }
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
        for folder in ["MacOS", "Resources"] {
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
        try sign()
    }

    // MARK: Signature

    /// Signs the app ad hoc, sealing everything inside it. A Vitral downloaded from the internet
    /// passes its "downloaded" history (provenance) on to the apps it writes, and macOS then
    /// checks their signature: an app whose signature does not cover its contents is "damaged".
    public func sign() throws {
        let (status, output) = Self.codesign(["--force", "--sign", "-", url.path])
        guard status == 0 else { throw WrapperError.signingFailed(output) }
    }

    /// Whether the signature covers the app as it is now.
    public var hasValidSignature: Bool {
        Self.codesign(["--verify", "--strict", url.path]).status == 0
    }

    private static func codesign(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, String(describing: error)) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Moves a prefix kept inside the app (apps made before Vitral 0.1.1) to Vitral's folder and
    /// signs the app. Only while the program is closed. Returns whether it moved one.
    @discardableResult
    public func moveEmbeddedPrefix(to home: VitralHome) throws -> Bool {
        let fm = FileManager.default
        var manifest = try readManifest()
        guard manifest.prefix == nil, fm.fileExists(atPath: embeddedPrefix.path),
              !WineSession.serverIsRunning(prefix: embeddedPrefix) else { return false }
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        let name = (info?["CFBundleIdentifier"] as? String).flatMap { Self.isFolderName($0) ? $0 : nil }
            ?? Self.bundleIdentifier(for: manifest.name)
        let target = home.prefixes.appendingPathComponent(name)
        guard !fm.fileExists(atPath: target.path) else { throw WrapperError.prefixInTheWay(target) }
        try fm.createDirectory(at: home.prefixes, withIntermediateDirectories: true)
        try fm.moveItem(at: embeddedPrefix, to: target)
        manifest.prefix = name
        try manifest.encoded().write(to: manifestURL)
        let shared = contents.appendingPathComponent("SharedSupport")
        if (try? fm.contentsOfDirectory(atPath: shared.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
            try? fm.removeItem(at: shared)
        }
        try sign()
        return true
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
