import Foundation

/// The installer inside a ZIP, as `ZipPackage.contents` finds it.
public struct ZipContents: Sendable, Equatable {
    /// Where the installer is inside the ZIP ("Shape it Level 2 PPlus_3.0.1.zip/Shape it Level 2
    /// PPlus.exe"). A ZIP inside the ZIP is shown with " › " ("Paint.NET.zip › setup.exe").
    public let setupPath: String
    /// The installer, analyzed (its companion files are counted from the ZIP's list).
    public let setup: InstallerReport
    /// The installer's icon (ICO).
    public let icon: Data?
}

/// Installers that arrive in a ZIP. WeTransfer, Google Drive and mail give a ZIP when someone
/// sends a folder: Shape It! Level 2 came as a folder with the Inno Setup `.exe` and its
/// `-1a.bin` and `-1b.bin`. Sometimes the ZIP holds another ZIP, or a folder inside a folder.
///
/// A ZIP is an installer when, at its top level (after the folders that only hold one folder),
/// there is an installer and no program of its own; otherwise it is a portable program, unpacked
/// into Program Files. Only the `.exe` and `.msi` of the top level are unpacked to decide.
public enum ZipPackage {
    /// ZIPs inside ZIPs followed, at most.
    static let maxNesting = 3

    /// The installer the ZIP holds, analyzed, or nil when the ZIP is a portable program.
    /// Unpacks only what it needs to look at, in a folder of `staging` removed afterwards.
    public static func contents(of zip: URL, in staging: URL) async throws -> ZipContents? {
        let work = staging.appendingPathComponent(UUID().uuidString + ".zipcheck")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var innermost = zip
        guard let found = try await find(in: zip, work: work, innermost: &innermost) else { return nil }
        let setup = found.probeRoot.appendingPathComponent(found.name)
        let report = try InstallerAnalyzer.analyze(fileAt: setup)
        let icon = (try? Data(contentsOf: setup, options: .alwaysMapped)).flatMap(PortableExecutable.icon)
        return ZipContents(setupPath: found.shownPath, setup: report, icon: icon)
    }

    /// What `unpack` leaves in its folder.
    enum Unpacked {
        /// The installer, with the whole ZIP (or the ZIP inside it) unpacked beside it.
        case installer(folder: URL, file: URL, report: InstallerReport)
        /// A portable program in a ZIP that came inside the ZIP: that inner ZIP, taken out.
        case portable(folder: URL, zip: URL)
    }

    /// Unpacks the installer the ZIP holds, into a new folder of `staging`, since the installer
    /// needs the files beside it. A portable program sent inside another ZIP gives that ZIP. Nil
    /// for a portable program in this very ZIP; nothing is left behind then. The caller removes
    /// the folder.
    static func unpack(_ zip: URL, in staging: URL) async throws -> Unpacked? {
        let work = staging.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // What was only needed to decide: the first look, and the ZIPs taken out of the ZIP.
        func clean(keeping kept: URL) {
            let keep = kept.path.dropFirst(work.path.count + 1).split(separator: "/").first.map(String.init)
            for item in (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent != keep {
                try? FileManager.default.removeItem(at: item)
            }
        }
        do {
            var innermost = zip
            guard let found = try await find(in: zip, work: work, innermost: &innermost) else {
                guard innermost != zip else {
                    try? FileManager.default.removeItem(at: work)
                    return nil
                }
                clean(keeping: innermost)
                return .portable(folder: work, zip: innermost)
            }
            let unpacked = work.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            guard try await tar(["-xf", found.archive.path, "-C", unpacked.path, "--exclude", "__MACOSX"]) == 0 else {
                throw InstallError.unsupported(tr("No pude descomprimir el archivo ZIP.", "I could not unpack the ZIP file."))
            }
            clean(keeping: unpacked)
            let file = unpacked.appendingPathComponent(found.root + found.name)
            return .installer(folder: work, file: file, report: try InstallerAnalyzer.analyze(fileAt: file))
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    // MARK: Deciding

    struct Found {
        /// The ZIP that holds the installer: the one given, or one taken out of it.
        let archive: URL
        /// The folder inside `archive` where the installer is ("Folder/" or "").
        let root: String
        let name: String
        /// Where its top level was unpacked to look at it (the rest are empty stand-ins).
        let probeRoot: URL
        let shownPath: String
    }

    /// `innermost` ends as the ZIP whose top level was looked at: a ZIP that only holds another
    /// ZIP is followed into it.
    static func find(in zip: URL, work: URL, innermost: inout URL, depth: Int = 0, shownPrefix: String = "") async throws -> Found? {
        innermost = zip
        guard let files = try await list(zip) else { return nil }
        let root = commonFolder(of: files)
        let top = files.filter { $0.hasPrefix(root) }.map { String($0.dropFirst(root.count)) }
        let topFiles = top.filter { !$0.contains("/") }
        let topFolders = Set(top.filter { $0.contains("/") }.map { String($0.prefix { $0 != "/" }) })
        func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

        let programs = topFiles.filter { ["exe", "msi"].contains(ext($0)) && !isUninstaller($0) }
        if programs.isEmpty {
            // A ZIP that only holds another ZIP (and maybe a note): look inside that one.
            let zips = topFiles.filter { ext($0) == "zip" }
            guard zips.count == 1, topFolders.isEmpty, depth < maxNesting else { return nil }
            let place = work.appendingPathComponent("nested-\(depth)")
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            guard try await tar(["-xf", zip.path, "-C", place.path, pattern(root + zips[0])]) == 0 else { return nil }
            let inner = place.appendingPathComponent(root + zips[0])
            return try await find(in: inner, work: work, innermost: &innermost, depth: depth + 1,
                                  shownPrefix: shownPrefix + root + zips[0] + " › ")
        }

        // The top level, to look at: its programs (and autorun.inf) unpacked, the rest as empty
        // stand-ins, so the companion files and the disc rules see every name.
        let probe = work.appendingPathComponent("probe-\(depth)")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let autorun = topFiles.first { $0.lowercased() == "autorun.inf" }
        let wanted = programs + (autorun.map { [$0] } ?? [])
        guard try await tar(["-xf", zip.path, "-C", probe.path] + wanted.map { pattern(root + $0) }) == 0 else { return nil }
        let probeRoot = probe.appendingPathComponent(root)
        for name in topFiles where !wanted.contains(name) {
            FileManager.default.createFile(atPath: probeRoot.appendingPathComponent(name).path, contents: nil)
        }
        for folder in topFolders {
            try? FileManager.default.createDirectory(at: probeRoot.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        var installers: [(name: String, report: InstallerReport)] = []
        var ownPrograms = 0
        for name in programs {
            guard let report = try? InstallerAnalyzer.analyze(fileAt: probeRoot.appendingPathComponent(name)) else { continue }
            if isInstaller(name, report) {
                installers.append((name, report))
            } else if isProgram(name, report) {
                ownPrograms += 1
            }
        }
        // A program of its own beside an installer: a portable program that brings one (a
        // runtime, a driver). On a disc, autorun.inf says which one installs.
        guard !installers.isEmpty, ownPrograms == 0 || autorun != nil else { return nil }

        let chosen: String
        if let setup = DiscImage.setupProgram(in: probeRoot)?.lastPathComponent,
           installers.contains(where: { $0.name == setup }) {
            chosen = setup
        } else {
            // Several and nothing says which (x86 and x64 packages): the 64-bit one, then the biggest.
            chosen = installers.max { a, b in
                let a64 = is64Bit(a.name, a.report), b64 = is64Bit(b.name, b.report)
                if a64 != b64 { return !a64 }
                return a.report.sizeBytes != b.report.sizeBytes ? a.report.sizeBytes < b.report.sizeBytes : a.name > b.name
            }!.name
        }
        return Found(archive: zip, root: root, name: chosen, probeRoot: probeRoot, shownPath: shownPrefix + root + chosen)
    }

    /// An installer to run: a known kind (Inno Setup, NSIS, MSI…), or an `.exe` that says it is a
    /// setup program in its name or its description ("Shape it Level 2 PPlus Setup").
    static func isInstaller(_ name: String, _ report: InstallerReport) -> Bool {
        guard report.executable?.isDLL != true, !ProgramAnalyzer.isRedistributable(name) else { return false }
        switch report.kind {
        case .innoSetup, .nsis, .msi, .wixBurn, .installShield, .sevenZipSFX: return true
        case .executable:
            if ProgramInstaller.looksLikeSetup(name) { return true }
            let version = report.executable?.version
            let words = [version?.fileDescription, version?.originalFilename].compactMap { $0 }
                .flatMap { $0.lowercased().split { !$0.isLetter } }
            return !words.contains { $0.hasPrefix("uninstal") || $0.hasPrefix("desinstal") }
                && words.contains { ["setup", "install", "installer", "installation", "instalador", "instalación"].contains($0) }
        default: return false
        }
    }

    /// A program of its own (what a portable program opens), not a helper or an uninstaller.
    static func isProgram(_ name: String, _ report: InstallerReport) -> Bool {
        guard report.kind == .executable, let info = report.executable, !info.isDLL,
              info.format == .pe32 || info.format == .pe32Plus else { return false }
        return !ProgramAnalyzer.isHelper(name) && !isUninstaller(name)
    }

    static func isUninstaller(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("unins") || name.hasPrefix("uninst")
    }

    static func is64Bit(_ name: String, _ report: InstallerReport) -> Bool {
        let name = name.lowercased()
        return report.executable?.bits == 64 || ["x64", "amd64", "win64"].contains { name.contains($0) }
    }

    // MARK: The ZIP

    /// The files in the ZIP (not folders), without what macOS and Windows add (`__MACOSX`,
    /// `.DS_Store`, `Thumbs.db`), or nil if it cannot be read.
    static func list(_ zip: URL) async throws -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init).filter { path in
            let parts = path.split(separator: "/")
            guard !path.hasSuffix("/"), !path.hasPrefix("/"), let last = parts.last else { return false }
            return !parts.contains { $0 == ".." || $0 == "__MACOSX" }
                && !last.hasPrefix(".") && !["thumbs.db", "desktop.ini"].contains(last.lowercased())
        }
    }

    /// The folders that only hold one folder, from the top: "Shape it Level 2 PPlus_3.0.1.zip/".
    static func commonFolder(of files: [String]) -> String {
        var root = ""
        while let first = files.first?.dropFirst(root.count), let slash = first.firstIndex(of: "/") {
            let folder = root + first[..<slash] + "/"
            guard files.allSatisfy({ $0.hasPrefix(folder) }) else { break }
            root = folder
        }
        return root
    }

    /// A name for `tar` to take literally: `[`, `*` and `?` are patterns to it.
    static func pattern(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "[]*?\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// The system's `tar` (bsdtar): it reads ZIP, ZIP64 included, and takes out single files.
    static func tar(_ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await WineSession.wait(for: process)
    }
}
