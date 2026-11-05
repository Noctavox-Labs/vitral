import Foundation

/// How a Windows program is packaged.
public enum InstallerKind: String, Codable, Sendable {
    case innoSetup
    case nsis
    case msi
    case wixBurn
    case installShield
    case sevenZipSFX
    case zip
    /// An `.exe` that is not a known installer: probably the program itself (portable).
    case executable
    case unknown
}

/// Everything Vitral can tell about a file without running it.
public struct InstallerReport: Codable, Sendable, Equatable {
    /// File name only (never the full path, so reports can be shared safely).
    public let fileName: String
    public let sizeBytes: Int64
    public let kind: InstallerKind
    /// Version of the installer format when known (for example Inno Setup "5.6.0").
    public let kindVersion: String?
    /// Headers of the file itself when it is an `.exe` (for installers, this is the
    /// installer's own executable, not the program it installs).
    public let executable: ExecutableInfo?
    /// Extra files next to it that belong to the same installer (for example Inno Setup's
    /// `-1a.bin` data files). They must stay in the same folder.
    public let companionFiles: [String]
    /// Tool that made the installer, when its script shows it (NSIS only, for now).
    public var builder: InstallerBuilder? = nil
    /// The installer's script runs PowerShell. Wine only has a stand-in for it, which does
    /// nothing and always answers "done".
    public var runsPowerShell = false
}

public enum InstallerAnalyzerError: Error, Equatable {
    case notFound
    case notAFile
}

/// Classifies Windows installers and programs by their signatures, without executing them.
public enum InstallerAnalyzer {
    /// Bytes scanned for installer markers. Installers keep them near the start.
    static let scanLimit = 32 * 1024 * 1024

    private static let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let sevenZipMagic: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

    /// Analyzes a file on disk.
    public static func analyze(fileAt url: URL) throws -> InstallerReport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw InstallerAnalyzerError.notFound
        }
        guard !isDirectory.boolValue else { throw InstallerAnalyzerError.notAFile }

        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let (kind, version) = classify(data.prefix(scanLimit), fileExtension: url.pathExtension)
        let executable = data.prefix(2) == Data([0x4D, 0x5A])
            ? PortableExecutable.parse(data)
            : nil
        let script = kind == .nsis ? NSISScript.facts(in: data, scanLimit: scanLimit) : nil

        return InstallerReport(
            fileName: url.lastPathComponent,
            sizeBytes: Int64(data.count),
            kind: kind,
            kindVersion: version,
            executable: executable,
            companionFiles: companionFiles(of: url, kind: kind),
            builder: script?.builder,
            runsPowerShell: script?.runsPowerShell ?? false
        )
    }

    /// Decides the packaging from the first bytes of a file (up to `scanLimit`).
    public static func classify(_ data: Data, fileExtension: String = "") -> (InstallerKind, String?) {
        let r = ByteReader(data: data)
        let head = r.bytes(0, min(8, r.count)).map(Array.init) ?? []

        if head == oleMagic {
            return fileExtension.lowercased() == "msi" ? (.msi, nil) : (.unknown, nil)
        }
        if Array(head.prefix(4)) == zipMagic { return (.zip, nil) }
        guard head.starts(with: [0x4D, 0x5A]) else { return (.unknown, nil) }

        if let version = innoSetupVersion(r) { return (.innoSetup, version) }
        if r.contains("JR.Inno.Setup") || r.contains("Inno Setup Setup Data") { return (.innoSetup, nil) }
        if r.contains("NullsoftInst") || r.contains("Nullsoft Install System") {
            return (.nsis, nsisVersion(r))
        }
        if let info = PortableExecutable.parse(data.prefix(1024 * 1024)),
           info.sectionNames.contains(".wixburn") {
            return (.wixBurn, nil)
        }
        if r.contains("InstallShield") { return (.installShield, nil) }
        if r.contains(sevenZipMagic) { return (.sevenZipSFX, nil) }
        return (.executable, nil)
    }

    /// "Inno Setup Setup Data (5.6.0)" or "(5.5.7) (u)" → "5.6.0".
    private static func innoSetupVersion(_ r: ByteReader) -> String? {
        let marker = Array("Inno Setup Setup Data (".utf8)
        guard let start = r.firstOffset(of: marker),
              let tail = r.bytes(start + marker.count, min(16, r.count - start - marker.count)) else { return nil }
        let version = String(decoding: tail.prefix { $0 != UInt8(ascii: ")") }, as: UTF8.self)
        return isVersionLike(version) ? version : nil
    }

    /// "Nullsoft Install System v3.08" → "3.08".
    private static func nsisVersion(_ r: ByteReader) -> String? {
        let marker = Array("Nullsoft Install System v".utf8)
        guard let start = r.firstOffset(of: marker),
              let tail = r.bytes(start + marker.count, min(12, r.count - start - marker.count)) else { return nil }
        let version = String(decoding: tail.prefix { $0 == UInt8(ascii: ".") || (48...57).contains($0) }, as: UTF8.self)
        return isVersionLike(version) ? version : nil
    }

    private static func isVersionLike(_ text: String) -> Bool {
        !text.isEmpty && text.first!.isNumber && text.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Files beside the installer that it needs: `<name>-1.bin`, `<name>-1a.bin`… (Inno Setup
    /// disk spanning) and `.cab` files next to an `.msi`.
    static func companionFiles(of url: URL, kind: InstallerKind) -> [String] {
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let base = url.deletingPathExtension().lastPathComponent.lowercased()

        return names.filter { name in
            let lower = name.lowercased()
            switch kind {
            case .innoSetup:
                return lower.hasPrefix(base + "-") && lower.hasSuffix(".bin")
            case .msi:
                return lower.hasSuffix(".cab")
            default:
                return false
            }
        }.sorted()
    }
}
