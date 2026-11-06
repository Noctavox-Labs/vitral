import Foundation

/// A technology a Windows program is built with. It decides which rules apply
/// (scaling, graphics, runtimes to install…).
public struct Technology: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case qt
        /// Qt with a graphical interface (Qt GUI). Qt Core alone can be a helper library of a
        /// program whose windows are plain Win32 (Winamp 5.9 uses it for networking).
        case qtGui
        /// Qt's embedded Chromium browser (QtWebEngine).
        case qtWebEngine
        /// Qt Quick / QML user interface.
        case qtQuick
        /// ANGLE: OpenGL ES on top of Direct3D, bundled by Qt and Chromium.
        case angle
        case electron
        /// Chromium Embedded Framework.
        case cef
        case dotNetFramework
        /// .NET (Core) 3.1 or newer.
        case dotNet
        case java
        case unity
        case unreal
        /// Microsoft Visual C++ runtime ("2015-2022", "2013"…).
        case visualCpp
        /// Internet Explorer's browser control (WebBrowser, MSHTML), shown inside the program's
        /// windows. Needs Wine Gecko.
        case internetExplorer
    }

    public let kind: Kind
    public let version: String?
    /// File that revealed it, relative to the analyzed folder.
    public let evidence: String

    public init(_ kind: Kind, version: String? = nil, evidence: String) {
        self.kind = kind
        self.version = version
        self.evidence = evidence
    }
}

public enum GraphicsAPI: String, Codable, Sendable, CaseIterable {
    case directDraw, direct3D8, direct3D9, direct3D10, direct3D11, direct3D12, openGL, vulkan
}

public enum AntiCheat: String, Codable, Sendable {
    case easyAntiCheat, battlEye, gameGuard, xigncode
}

/// What Vitral can tell about an installed (or portable) Windows program from its folder.
public struct ProgramReport: Codable, Sendable, Equatable {
    public let folderName: String
    public let fileCount: Int
    public let totalBytes: Int64
    /// The program to open, relative to the folder with `/` separators. `nil` if none was found.
    public let mainExecutable: String?
    public let executable: ExecutableInfo?
    /// Other programs in the folder that could be the right one, best first.
    public let alternatives: [String]
    public let technologies: [Technology]
    /// Graphics interfaces the main program (and the DLLs it loads from its folder) import.
    /// Frameworks that choose at run time (Qt, Chromium) are not counted, so this is often
    /// empty for them.
    public let graphics: [GraphicsAPI]
    public let antiCheat: [AntiCheat]
    /// Installers of runtimes shipped with the program (`vc_redist.x86.exe`, `DXSETUP.exe`…).
    public let bundledRedistributables: [String]

    public func technology(_ kind: Technology.Kind) -> Technology? {
        technologies.first { $0.kind == kind }
    }
}

public enum ProgramAnalyzerError: Error, Equatable {
    case notFound
    case notAFolder
}

/// Looks through the folder of an installed program, without running anything.
public enum ProgramAnalyzer {
    /// Safety limits for huge folders.
    static let maxFiles = 50_000
    static let maxExecutableDepth = 3

    /// `preferring` names the program to open (a path relative to the folder), when it is
    /// already known, for example from the installer's shortcut.
    public static func analyze(folderAt url: URL, preferring: String? = nil) throws -> ProgramReport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ProgramAnalyzerError.notFound
        }
        guard isDirectory.boolValue else { throw ProgramAnalyzerError.notAFolder }

        let files = listFiles(in: url)
        let lowerPaths = Set(files.map { $0.path.lowercased() })
        let byName = Dictionary(grouping: files) { ($0.path as NSString).lastPathComponent.lowercased() }

        func parse(_ path: String) -> ExecutableInfo? {
            PortableExecutable.parse(fileAt: url.appendingPathComponent(path))
        }

        // Main program.
        var ranked = rankExecutables(files, folderName: url.lastPathComponent, parse: parse)
        if let preferring, let index = ranked.firstIndex(where: { $0.path.lowercased() == preferring.lowercased() }) {
            ranked.insert(ranked.remove(at: index), at: 0)
        }
        let main = ranked.first
        let mainInfo = main?.info

        // DLLs the main program loads from its own folder (Qt, engines…): they also need
        // the Visual C++ runtime, and some of them draw the graphics.
        let mainFolder = main.map { ($0.path as NSString).deletingLastPathComponent } ?? ""
        var importers: [ExecutableInfo] = mainInfo.map { [$0] } ?? []
        var importerPaths: [String] = main.map { [$0.path] } ?? []
        var graphicsImporters = importers
        for dll in mainInfo?.imports ?? [] {
            let local = mainFolder.isEmpty ? dll : mainFolder + "/" + dll
            guard lowerPaths.contains(local.lowercased()),
                  let file = files.first(where: { $0.path.lowercased() == local.lowercased() }),
                  let info = parse(file.path) else { continue }
            importers.append(info)
            importerPaths.append(file.path)
            if !choosesGraphicsAtRuntime(dll) { graphicsImporters.append(info) }
        }

        var technologies = detectTechnologies(
            files: files, byName: byName, parse: parse,
            read: { try? Data(contentsOf: url.appendingPathComponent($0)) }
        )
        if let runtime = mainInfo?.dotNetRuntime, let main {
            technologies.append(Technology(.dotNetFramework, version: runtime, evidence: main.path))
        }
        if let visualCpp = visualCppRuntime(importers: importers, evidence: main?.path) {
            technologies.append(visualCpp)
        }
        // Pages shown with Internet Explorer's control, by the program or a DLL of its own.
        if let browser = zip(importers, importerPaths).first(where: { info, path in
            WineGecko.usesBrowser(imports: info.imports, contents: WineGecko.contents(of: url.appendingPathComponent(path)))
        }) {
            technologies.append(Technology(.internetExplorer, evidence: browser.1))
        }

        return ProgramReport(
            folderName: url.lastPathComponent,
            fileCount: files.count,
            totalBytes: files.reduce(0) { $0 + $1.size },
            mainExecutable: main?.path,
            executable: mainInfo,
            alternatives: ranked.dropFirst().prefix(5).map(\.path),
            technologies: technologies,
            graphics: graphicsAPIs(graphicsImporters.flatMap(\.imports)),
            antiCheat: detectAntiCheat(byName: byName, lowerPaths: lowerPaths),
            bundledRedistributables: files.map(\.path).filter { isRedistributable(($0 as NSString).lastPathComponent) }.sorted()
        )
    }

    // MARK: Files

    struct File {
        let path: String
        let size: Int64
        var depth: Int { path.split(separator: "/").count - 1 }
    }

    /// Regular files under `url`, relative paths. Symbolic links are skipped (a Wine prefix
    /// links to the whole Mac disk).
    static func listFiles(in url: URL) -> [File] {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return [] }
        var files: [File] = []
        while let path = enumerator.nextObject() as? String, files.count < maxFiles {
            guard let attributes = enumerator.fileAttributes else { continue }
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?:
                files.append(File(path: path, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0))
            case .typeSymbolicLink?:
                enumerator.skipDescendants()
            default:
                break
            }
        }
        return files
    }

    // MARK: Main program

    struct Candidate {
        let path: String
        let info: ExecutableInfo
        let score: Int
    }

    /// Executables that are never the program itself: uninstallers, runtime installers,
    /// helper processes of frameworks, crash reporters, updaters.
    static func isHelper(_ name: String) -> Bool {
        let name = name.lowercased()
        if isRedistributable(name) { return true }
        let prefixes = ["unins", "uninst", "crashpad", "crashreporter", "crashhandler", "unitycrashhandler",
                        "qtwebengineprocess", "cefsharp.browsersubprocess", "notification_helper", "elevate",
                        "squirrel", "update.exe", "updater", "autoupdate", "easyanticheat", "beservice",
                        "start_protected_game", "setup", "install"]
        return prefixes.contains { name.hasPrefix($0) } || name.contains("helper")
    }

    static func isRedistributable(_ name: String) -> Bool {
        let name = name.lowercased()
        guard name.hasSuffix(".exe") || name.hasSuffix(".msi") else { return false }
        let prefixes = ["vc_redist", "vcredist", "dxsetup", "dxwebsetup", "dotnetfx", "ndp4", "ndp35",
                        "windowsdesktop-runtime", "dotnet-runtime", "aspnetcore-runtime", "oalinst",
                        "physx", "directx", "xnafx", "jre-", "msxml"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// Letters and digits only, lower-cased: "Shape it Level 1 PPlus" → "shapeitlevel1pplus".
    static func simplified(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func rankExecutables(
        _ files: [File], folderName: String, parse: (String) -> ExecutableInfo?
    ) -> [Candidate] {
        let folder = simplified(folderName)
        var candidates: [Candidate] = []

        for file in files where file.path.lowercased().hasSuffix(".exe") && file.depth <= maxExecutableDepth {
            let fileName = (file.path as NSString).lastPathComponent
            guard !isHelper(fileName), let info = parse(file.path), !info.isDLL,
                  info.format == .pe32 || info.format == .pe32Plus else { continue }

            let name = simplified((fileName as NSString).deletingPathExtension)
            var score = 0
            if info.subsystem == .gui { score += 40 }
            score += [20, 10, 5, 0][min(file.depth, 3)]
            if info.hasIcon { score += 15 }
            if !folder.isEmpty, !name.isEmpty {
                if name == folder { score += 40 } else if folder.contains(name) || name.contains(folder) { score += 20 }
            }
            // The product named like the folder: "MetaTrader 5 Client Terminal" in "MetaTrader 5"
            // (its editor, "MetaQuotes Language 5 Editor", sits next to it).
            if let product = info.version?.productName.map(simplified), !product.isEmpty,
               product == folder || product == name || (folder.count >= 4 && product.contains(folder)) {
                score += 10
            }
            // Bigger programs win ties: up to 10 points, one per 2 MB.
            score += Int(min(10, file.size / 2_000_000))
            candidates.append(Candidate(path: file.path, info: info, score: score))
        }
        return candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    }

    // MARK: Technologies

    static func detectTechnologies(
        files: [File], byName: [String: [File]], parse: (String) -> ExecutableInfo?, read: (String) -> Data?
    ) -> [Technology] {
        var found: [Technology] = []

        func first(_ names: [String]) -> File? {
            for name in names { if let file = byName[name]?.min(by: { $0.depth < $1.depth }) { return file } }
            return nil
        }
        func versionOf(_ file: File) -> String? {
            let info = parse(file.path)?.version
            return info?.productVersion ?? info?.fileVersion
        }

        if let core = first(["qt6core.dll", "qt5core.dll", "qtcore4.dll"]) {
            let version = versionOf(core).map { shortVersion($0, parts: 3) }
                ?? (core.path.lowercased().hasSuffix("qt6core.dll") ? "6" : core.path.lowercased().hasSuffix("qt5core.dll") ? "5" : "4")
            found.append(Technology(.qt, version: version, evidence: core.path))
        }
        if let gui = first(["qt6gui.dll", "qt5gui.dll", "qtgui4.dll"]) {
            found.append(Technology(.qtGui, evidence: gui.path))
        }
        if let quick = first(["qt6quick.dll", "qt5quick.dll"]) {
            found.append(Technology(.qtQuick, evidence: quick.path))
        }
        if let engine = first(["qtwebengineprocess.exe", "qt6webenginecore.dll", "qt5webenginecore.dll"]) {
            found.append(Technology(.qtWebEngine, evidence: engine.path))
        }
        if let egl = first(["libegl.dll"]), first(["libglesv2.dll"]) != nil {
            found.append(Technology(.angle, evidence: egl.path))
        }
        if let asar = files.first(where: { $0.path.lowercased().hasSuffix("resources/app.asar") })
            ?? files.first(where: { $0.path.lowercased().hasSuffix("resources/default_app.asar") }) {
            found.append(Technology(.electron, evidence: asar.path))
        }
        if let cef = first(["libcef.dll"]) {
            found.append(Technology(.cef, version: versionOf(cef), evidence: cef.path))
        }
        if let config = files.first(where: { $0.path.lowercased().hasSuffix(".runtimeconfig.json") }) {
            found.append(Technology(.dotNet, version: read(config.path).flatMap { dotNetVersion(fromRuntimeConfig: $0) }, evidence: config.path))
        } else if let coreclr = first(["coreclr.dll", "hostfxr.dll"]) {
            found.append(Technology(.dotNet, version: versionOf(coreclr).map { shortVersion($0, parts: 3) }, evidence: coreclr.path))
        }
        if let java = first(["jvm.dll", "java.exe", "javaw.exe"])
            ?? files.first(where: { $0.path.lowercased().hasSuffix(".jar") }) {
            found.append(Technology(.java, evidence: java.path))
        }
        if let unity = first(["unityplayer.dll"]) {
            found.append(Technology(.unity, version: versionOf(unity).map { shortVersion($0, parts: 3) }, evidence: unity.path))
        } else if let manager = files.first(where: { $0.path.lowercased().hasSuffix("_data/globalgamemanagers") }) {
            found.append(Technology(.unity, evidence: manager.path))
        }
        if let unreal = files.first(where: { $0.path.lowercased().hasSuffix("-win64-shipping.exe") })
            ?? files.first(where: { $0.path.lowercased().contains("engine/binaries/") }) {
            found.append(Technology(.unreal, evidence: unreal.path))
        }
        return found
    }

    /// The Visual C++ runtime the program needs, from what it and its DLLs import.
    static func visualCppRuntime(importers: [ExecutableInfo], evidence: String?) -> Technology? {
        let families: [(dll: String, name: String)] = [
            ("vcruntime140.dll", "2015-2022"), ("msvcp140.dll", "2015-2022"),
            ("msvcr120.dll", "2013"), ("msvcp120.dll", "2013"),
            ("msvcr110.dll", "2012"), ("msvcp110.dll", "2012"),
            ("msvcr100.dll", "2010"), ("msvcp100.dll", "2010"),
            ("msvcr90.dll", "2008"), ("msvcp90.dll", "2008"),
            ("msvcr80.dll", "2005"), ("msvcp80.dll", "2005"),
        ]
        let imports = Set(importers.flatMap(\.imports))
        let names = families.filter { imports.contains($0.dll) }.map(\.name)
        guard let newest = names.first, let evidence else { return nil }
        return Technology(.visualCpp, version: newest, evidence: evidence)
    }

    /// Framework DLLs that pick their graphics when the program runs (Qt tries OpenGL, ANGLE
    /// or software; Chromium uses ANGLE). What they import says nothing about the program.
    static func choosesGraphicsAtRuntime(_ dll: String) -> Bool {
        ["qt5", "qt6", "qtcore4", "qtgui4", "libcef", "libegl", "libglesv2", "chrome_elf"]
            .contains { dll.hasPrefix($0) }
    }

    static func graphicsAPIs(_ imports: [String]) -> [GraphicsAPI] {
        let map: [String: GraphicsAPI] = [
            "ddraw.dll": .directDraw, "d3d8.dll": .direct3D8, "d3d9.dll": .direct3D9,
            "d3d10.dll": .direct3D10, "d3d10_1.dll": .direct3D10, "d3d11.dll": .direct3D11,
            "d3d12.dll": .direct3D12, "opengl32.dll": .openGL, "vulkan-1.dll": .vulkan,
        ]
        let found = Set(imports.compactMap { map[$0] })
        return GraphicsAPI.allCases.filter(found.contains)
    }

    static func detectAntiCheat(byName: [String: [File]], lowerPaths: Set<String>) -> [AntiCheat] {
        func hasFolder(_ name: String) -> Bool {
            lowerPaths.contains { $0.hasPrefix(name + "/") || $0.contains("/" + name + "/") }
        }
        func hasFile(_ predicate: (String) -> Bool) -> Bool { byName.keys.contains(where: predicate) }

        var found: [AntiCheat] = []
        if hasFolder("easyanticheat") || hasFile({ $0.hasPrefix("easyanticheat") }) { found.append(.easyAntiCheat) }
        if hasFolder("battleye") || hasFile({ $0.hasPrefix("beservice") || $0.hasPrefix("beclient") }) { found.append(.battlEye) }
        if hasFolder("gameguard") || hasFile({ $0 == "gameguard.des" || $0 == "gamemon.des" }) { found.append(.gameGuard) }
        if hasFolder("xigncode") || hasFile({ $0 == "x3.xem" }) { found.append(.xigncode) }
        return found
    }

    /// Framework version from a `.runtimeconfig.json` ("8.0.0"), preferring the desktop runtime.
    static func dotNetVersion(fromRuntimeConfig data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = json["runtimeOptions"] as? [String: Any] else { return nil }
        var frameworks = (options["frameworks"] as? [[String: Any]]) ?? []
        if let single = options["framework"] as? [String: Any] { frameworks.insert(single, at: 0) }
        let desktop = frameworks.first { ($0["name"] as? String)?.hasPrefix("Microsoft.WindowsDesktop") == true }
        return (desktop ?? frameworks.first)?["version"] as? String
    }

    /// "5.12.4.0" → "5.12.4" (with `parts` = 3).
    static func shortVersion(_ version: String, parts: Int) -> String {
        version.split(separator: ".").prefix(parts).joined(separator: ".")
    }
}
