import Foundation

/// A Windows function a program uses that the engine does not have, or a whole DLL that is
/// nowhere (not in the engine, the program's folder or the prefix).
public struct MissingImport: Codable, Sendable, Hashable {
    /// Lower-cased, such as "user32.dll".
    public let dll: String
    /// `nil` when the whole DLL is missing.
    public let function: String?
    /// Loaded the first time it is used, not when the program starts.
    public let delayLoaded: Bool
    /// File that uses it, such as "aTube Catcher.exe".
    public let usedBy: String

    public init(dll: String, function: String?, delayLoaded: Bool, usedBy: String) {
        self.dll = dll
        self.function = function
        self.delayLoaded = delayLoaded
        self.usedBy = usedBy
    }

    /// "user32.IsWindowArranged", or "d3d12core.dll" when the whole DLL is missing.
    public var label: String {
        guard let function else { return dll }
        return (dll.hasSuffix(".dll") ? String(dll.dropLast(4)) : dll) + "." + function
    }

    /// One line for the logs: "Falta en el motor: user32.IsWindowArranged (a demanda, aTube Catcher.exe)".
    public var logLine: String {
        let when = delayLoaded ? tr("a demanda, ", "on demand, ") : ""
        return function == nil
            ? tr("No encuentro: \(label) (\(when)\(usedBy))", "Not found: \(label) (\(when)\(usedBy))")
            : tr("Falta en el motor: \(label) (\(when)\(usedBy))", "Missing in the engine: \(label) (\(when)\(usedBy))")
    }

    /// The first few labels, without repeats: "user32.IsWindowArranged, ole32.RoGetAgileReference and 3 more".
    public static func summary(_ items: [MissingImport], limit: Int = 3) -> String {
        var labels: [String] = []
        for label in items.map(\.label) where !labels.contains(label) { labels.append(label) }
        let shown = labels.prefix(limit).joined(separator: ", ")
        let rest = labels.count - min(labels.count, limit)
        return rest == 0 ? shown : shown + tr(" y \(rest) más", " and \(rest) more")
    }
}

/// Compares the functions a program imports with the ones the engine's DLLs export, without
/// running anything.
///
/// Wine starts a program even if it imports a function Wine lacks: it puts a stub in its place
/// that stops the program if it is ever called. So a missing function is a risk, not a sure
/// failure. Programs built on Chromium (Electron, CEF, QtWebEngine) stop on purpose when a
/// delay-loaded function is missing: aTube Catcher (Electron 37) closes on CrossOver 24 because
/// of `user32.IsWindowArranged`, from Windows 11: Chromium's delay-load hook
/// (`chrome::HandleDelayLoadFailureCommon`) stops it, and Crashpad ends it with status 3.
public enum EngineCheck {
    /// Most files to follow: the program and the DLLs of its own folder it loads.
    static let maxFiles = 200

    /// Folder of the engine's Windows DLLs for programs of `bits` bits.
    public static func dllFolder(of engine: InstalledEngine, bits: Int) -> URL {
        engine.wineRoot.appendingPathComponent(bits == 32 ? "lib/wine/i386-windows" : "lib/wine/x86_64-windows")
    }

    /// Checks `program` and the DLLs of its folder it loads against the engine. With `prefix`
    /// the DLLs installed in Windows' system folder count too (Visual C++ and other runtimes).
    public static func missingImports(program: URL, engine: InstalledEngine, prefix: URL? = nil) -> [MissingImport] {
        guard let image = PortableExecutable.image(fileAt: program) else { return [] }
        let bits = image.format == .pe32 ? 32 : 64
        var folders = [dllFolder(of: engine, bits: bits)]
        if let prefix {
            folders.append(prefix.appendingPathComponent(bits == 32 ? "drive_c/windows/syswow64" : "drive_c/windows/system32"))
        }
        return missingImports(program: program, systemFolders: folders)
    }

    /// `systemFolders` hold the DLLs Windows would provide, the engine's first.
    static func missingImports(program: URL, systemFolders: [URL]) -> [MissingImport] {
        let own = dllsBeside(program)
        var exportCache: [String: Set<String>] = [:]
        func exports(of url: URL) -> Set<String> {
            if let cached = exportCache[url.path] { return cached }
            let names = PortableExecutable.image(fileAt: url)?.exportedNames() ?? []
            exportCache[url.path] = names
            return names
        }
        func systemDLL(_ name: String) -> URL? {
            systemFolders.lazy.map { $0.appendingPathComponent(name) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        var missing: [MissingImport] = []
        var seen = Set<MissingImport>()
        var queue = [program]
        var followed: Set<String> = [program.lastPathComponent.lowercased()]
        var next = 0
        while next < queue.count {
            let file = queue[next]
            next += 1
            guard let image = PortableExecutable.image(fileAt: file) else { continue }
            let user = file.lastPathComponent
            for dll in image.importTable() where !isAPISet(dll.name) {
                if let local = own[dll.name] {
                    if queue.count < maxFiles, followed.insert(dll.name).inserted { queue.append(local) }
                    continue
                }
                guard let url = systemDLL(dll.name) else {
                    let item = MissingImport(dll: dll.name, function: nil, delayLoaded: dll.delayLoaded, usedBy: user)
                    if seen.insert(item).inserted { missing.append(item) }
                    continue
                }
                let available = exports(of: url)
                for function in dll.functions where !available.contains(function) {
                    let item = MissingImport(dll: dll.name, function: function, delayLoaded: dll.delayLoaded, usedBy: user)
                    if seen.insert(item).inserted { missing.append(item) }
                }
            }
        }
        // The ones already seen stopping a program go first; the rest keep their order.
        return missing.enumerated()
            .sorted { (knownToStop.contains($0.element.label) ? 0 : 1, $0.offset) < (knownToStop.contains($1.element.label) ? 0 : 1, $1.offset) }
            .map(\.element)
    }

    /// Functions whose absence has stopped a program at start.
    /// - `user32.IsWindowArranged`: Electron 37 / Chromium 138 (aTube Catcher on CrossOver 24).
    static let knownToStop: Set<String> = ["user32.IsWindowArranged"]

    /// What to tell the person after installing, or `nil` if nothing is missing.
    public static func warning(_ missing: [MissingImport], engine: WineEngine) -> String? {
        explanation(missing, engine: engine).map { tr("Puede que no abra: ", "It may not open: ") + $0 + "." }
    }

    /// What is missing, in words: the functions the engine lacks and the DLLs that are nowhere
    /// (a DLL of the program's own that did not get installed, or a Windows one Wine does not have).
    public static func explanation(_ missing: [MissingImport], engine: WineEngine) -> String? {
        let functions = missing.filter { $0.function != nil }, dlls = missing.filter { $0.function == nil }
        var parts: [String] = []
        if !functions.isEmpty {
            parts.append(tr("usa funciones de Windows que el motor \(engine.name) todavía no tiene (\(MissingImport.summary(functions)))",
                            "it uses Windows functions the \(engine.name) engine does not have yet (\(MissingImport.summary(functions)))"))
        }
        if !dlls.isEmpty {
            parts.append(tr("no encuentro DLL que necesita (\(MissingImport.summary(dlls)))",
                            "DLLs it needs are nowhere to be found (\(MissingImport.summary(dlls)))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: tr("; y ", "; and "))
    }

    /// API sets ("api-ms-win-core-…", "ext-ms-…") are names Wine resolves to its real DLLs.
    static func isAPISet(_ dll: String) -> Bool {
        dll.hasPrefix("api-ms-") || dll.hasPrefix("ext-ms-")
    }

    /// DLLs in the program's folder, by lower-cased name: Windows looks there first.
    static func dllsBeside(_ program: URL) -> [String: URL] {
        let folder = program.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: [String: URL] = [:]
        for name in names where name.lowercased().hasSuffix(".dll") {
            found[name.lowercased()] = folder.appendingPathComponent(name)
        }
        return found
    }
}
