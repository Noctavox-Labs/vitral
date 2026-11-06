import Foundation

/// Wine Gecko: the HTML engine Wine's Internet Explorer (MSHTML) draws pages with. Programs that
/// show pages inside their windows with Internet Explorer's control (WebBrowser) need it; without
/// it those pages stay blank (Encarta 2009 shows its articles that way).
///
/// Vitral keeps Wine's MSHTML off for every other program (`InstalledEngine.environment`): turned
/// on without Gecko, Wine stops to offer a download and waits for an answer. Where Gecko is in the
/// prefix, MSHTML is on.
///
/// The archives are WineHQ's own, pinned to their checksums. Each is unpacked once under
/// Components and cloned into the prefixes that need it, where Wine's own installer would put it
/// (an APFS clone takes no space). `GeckoPath` in the registry points there, in the registry view
/// of its architecture: 32-bit MSHTML reads the 32-bit view (`Wow6432Node`).
public enum WineGecko {
    public static let version = "2.47.4"
    static let license = "MPL-2.0 (Mozilla code), built by the Wine project"
    static let source = URL(string: "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-src.tar.xz")!

    public enum Architecture: String, Sendable, CaseIterable {
        case x86
        case x86_64
    }

    public static let x86 = Component(
        id: "wine-gecko-2.47.4-x86", name: "Wine Gecko 2.47.4 (32-bit)",
        url: URL(string: "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86.tar.xz")!,
        sha256: "2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6", bytes: 43_025_064,
        archiveRoot: "wine-gecko-2.47.4-x86", license: license, source: source)

    public static let x86_64 = Component(
        id: "wine-gecko-2.47.4-x86_64", name: "Wine Gecko 2.47.4 (64-bit)",
        url: URL(string: "https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.tar.xz")!,
        sha256: "fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814", bytes: 41_935_496,
        archiveRoot: "wine-gecko-2.47.4-x86_64", license: license, source: source)

    public static func component(_ architecture: Architecture) -> Component {
        architecture == .x86 ? x86 : x86_64
    }

    /// The recipe, as listed in the app's manifest.
    public static func recipe(because: String) -> AppliedRecipe { AppliedRecipe(id: "wine-gecko", because: because) }

    /// The Gecko a program needs: the one of its own architecture.
    public static func architecture(of program: ExecutableInfo?) -> Architecture {
        program?.format == .pe32Plus ? .x86_64 : .x86
    }

    /// Whether the prefix is 64-bit, with 32-bit programs in `syswow64`.
    static func isWow64(_ prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/syswow64").path)
    }

    /// Windows' folder for this architecture's system files.
    static func systemFolder(_ architecture: Architecture, prefix: URL) -> String {
        architecture == .x86 && isWow64(prefix) ? "syswow64" : "system32"
    }

    /// Where it goes in the prefix: `C:\windows\syswow64\gecko\2.47.4\wine_gecko` for 32 bits.
    public static func folder(_ architecture: Architecture, in prefix: URL) -> URL {
        prefix.appendingPathComponent("drive_c/windows/\(systemFolder(architecture, prefix: prefix))/gecko/\(version)/wine_gecko")
    }

    /// `GeckoPath`, read by MSHTML of this architecture.
    static func registry(_ architecture: Architecture, prefix: URL) -> RegistryValue {
        let software = architecture == .x86 && isWow64(prefix) ? #"Software\Wow6432Node"# : "Software"
        return .string(#"HKEY_LOCAL_MACHINE\"# + software + #"\Wine\MSHTML\"# + version, "GeckoPath",
                       #"C:\windows\"# + systemFolder(architecture, prefix: prefix) + #"\gecko\"# + version + #"\wine_gecko"#)
    }

    /// Whether this architecture's Gecko is in the prefix (MSHTML checks its `VERSION` file).
    public static func isInstalled(_ architecture: Architecture, prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder(architecture, in: prefix).appendingPathComponent("VERSION").path)
    }

    /// Whether any Gecko is in the prefix: then Wine's MSHTML is on for its programs.
    public static func isInstalled(prefix: URL) -> Bool {
        Architecture.allCases.contains { isInstalled($0, prefix: prefix) }
    }

    /// Downloads it if needed and puts it into the session's prefix. `progress` goes from 0 to 1.
    ///
    /// MSHTML is registered first, as wineboot would have done had it not been off when the prefix
    /// was made: its classes, the protocols pages use (`res:`, `about:`, `javascript:`) and the
    /// content types of files (`.htm` is `text/html`). Without them Encarta 2009 searched but
    /// showed blank pages. Gecko's folder goes in last, so finding it means everything is in place.
    public static func install(_ architecture: Architecture, in session: WineSession, home: VitralHome,
                               log: FileHandle = .nullDevice,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let piece = component(architecture)
        let unpacked = try await ComponentInstaller(home: home).install(piece) { progress(0.8 * $0) }
        let prefix = session.prefix

        // Both registry views: a 64-bit prefix's 32-bit programs read theirs (`Wow6432Node`).
        for regsvr32 in isWow64(prefix) ? [#"C:\windows\system32\regsvr32.exe"#, #"C:\windows\syswow64\regsvr32.exe"#]
                                        : [#"C:\windows\system32\regsvr32.exe"#] {
            let process = session.process([regsvr32, "/s", "mshtml.dll"], output: log)
            process.environment?["WINEDLLOVERRIDES"] = InstalledEngine.dllOverrides(prefix: prefix, internetExplorer: true)
            let status = try await WineSession.wait(for: process)
            await session.waitForServer()
            guard status == 0 else { throw WineError.failed(command: "regsvr32 mshtml.dll", status: status) }
        }
        progress(0.9)
        try await session.importRegistry([registry(architecture, prefix: prefix)])

        let destination = folder(architecture, in: prefix)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".wine_gecko-\(UUID().uuidString)")
        // On APFS this is a clone: no space used until something changes.
        try fileManager.copyItem(at: unpacked, to: staged)
        try? fileManager.removeItem(at: staged.appendingPathComponent(ComponentInstaller.receiptName))
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: staged, to: destination)
        progress(1)
    }

    // MARK: Who needs it

    /// DLLs of Internet Explorer's browser a program can import.
    static let browserLibraries: Set<String> = ["mshtml.dll", "shdocvw.dll", "ieframe.dll"]

    /// Identifiers a program names to create Internet Explorer's browser: `CLSID_WebBrowser`, its
    /// version 1 (`CLSID_WebBrowser_V1`) and the program ID "Shell.Explorer" (ASCII and UTF-16),
    /// as programs store them. Delphi, MFC (`CHtmlView`), Visual Basic and ATL programs keep one
    /// of these in their own file.
    static let browserMarkers: [Data] = {
        func guid(_ text: String) -> Data {
            let uuid = UUID(uuidString: text)!.uuid
            // In memory, the first three fields are little-endian.
            let bytes = [uuid.3, uuid.2, uuid.1, uuid.0, uuid.5, uuid.4, uuid.7, uuid.6,
                         uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15]
            return Data(bytes)
        }
        return [
            guid("8856F961-340A-11D0-A96B-00C04FD705A2"),
            guid("EAB22AC3-30C1-11CF-A7EB-0000C05BAE0B"),
            Data("Shell.Explorer".utf8),
            "Shell.Explorer".data(using: .utf16LittleEndian)!,
        ]
    }()

    /// Whether a program file uses Internet Explorer's browser: it imports one of its DLLs, or its
    /// contents name the browser.
    static func usesBrowser(imports: [String], contents: Data?) -> Bool {
        if imports.contains(where: { browserLibraries.contains($0.lowercased()) }) { return true }
        guard let contents else { return false }
        return browserMarkers.contains { contents.range(of: $0) != nil }
    }

    /// Files larger than this are not searched: they are games, and programs that show pages
    /// with Internet Explorer's control are far smaller.
    static let largestSearched = 64 * 1024 * 1024

    /// A program file's contents, mapped rather than read, if it is small enough to search.
    static func contents(of file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= largestSearched else { return nil }
        return try? Data(contentsOf: file, options: .alwaysMapped)
    }

    /// Whether the program at `program`, or a DLL from its folder that it loads, uses Internet
    /// Explorer's browser. For apps made before Vitral brought Gecko.
    public static func usesBrowser(program: URL) -> Bool {
        guard let info = PortableExecutable.parse(fileAt: program) else { return false }
        if usesBrowser(imports: info.imports, contents: contents(of: program)) { return true }
        let folder = program.deletingLastPathComponent()
        return info.imports.contains { dll in
            let file = folder.appendingPathComponent(dll)
            guard let library = PortableExecutable.parse(fileAt: file) else { return false }
            return usesBrowser(imports: library.imports, contents: contents(of: file))
        }
    }
}
