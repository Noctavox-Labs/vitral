import CryptoKit
import Foundation

/// A downloadable piece Vitral needs to run Windows programs: a Wine build, or the libraries
/// it loads. Every download is pinned to a SHA-256 checksum and comes from an official source.
public struct Component: Codable, Sendable, Equatable {
    /// Folder name under `Components/`, such as "wine-cx24.0.7_7".
    public let id: String
    public let name: String
    public let url: URL
    public let sha256: String
    public let bytes: Int64
    /// Folder inside the archive whose contents become the component.
    public let archiveRoot: String
    /// If not empty, only these archive members are extracted (tar patterns).
    public let members: [String]
    /// License of what is inside, shown to people and kept in the notices.
    public let license: String
    /// Where the source code is (required for LGPL components that may be redistributed).
    public let source: URL

    public init(
        id: String, name: String, url: URL, sha256: String, bytes: Int64, archiveRoot: String,
        members: [String] = [], license: String, source: URL
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
        self.archiveRoot = archiveRoot
        self.members = members
        self.license = license
        self.source = source
    }
}

/// Where Vitral keeps its files. `VITRAL_HOME` overrides it (tests use a temporary folder).
public struct VitralHome: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var `default`: VitralHome {
        if let custom = ProcessInfo.processInfo.environment["VITRAL_HOME"], !custom.isEmpty {
            return VitralHome(url: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VitralHome(url: support.appendingPathComponent("Vitral"))
    }

    public var components: URL { url.appendingPathComponent("Components") }

    public func folder(of component: Component) -> URL { components.appendingPathComponent(component.id) }
}

public enum ComponentError: Error, Equatable, CustomStringConvertible {
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case missingArchiveRoot(String)

    public var description: String {
        switch self {
        case .downloadFailed(let reason):
            tr("No se pudo descargar: \(reason)", "Download failed: \(reason)")
        case .checksumMismatch(let expected, let actual):
            tr("La descarga no coincide con la publicada (SHA-256 esperado \(expected), recibido \(actual)). No se instaló nada.",
               "The download does not match the published one (expected SHA-256 \(expected), got \(actual)). Nothing was installed.")
        case .extractionFailed(let reason):
            tr("No se pudo descomprimir: \(reason)", "Could not unpack: \(reason)")
        case .missingArchiveRoot(let root):
            tr("El archivo no tiene la carpeta esperada «\(root)».", "The archive lacks the expected folder “\(root)”.")
        }
    }
}

/// Downloads, verifies and unpacks components.
public struct ComponentInstaller: Sendable {
    public let home: VitralHome
    /// Fetches a URL into a local file. Replaceable in tests.
    public var fetch: @Sendable (URL) async throws -> URL

    /// Name of the receipt written inside a component folder once it is complete.
    static let receiptName = ".vitral-component.json"

    public init(home: VitralHome = .default, fetch: (@Sendable (URL) async throws -> URL)? = nil) {
        self.home = home
        self.fetch = fetch ?? ComponentInstaller.download
    }

    /// `true` if the component is unpacked and was verified against this exact checksum.
    public func isInstalled(_ component: Component) -> Bool {
        let receipt = home.folder(of: component).appendingPathComponent(Self.receiptName)
        guard let data = try? Data(contentsOf: receipt),
              let saved = try? JSONDecoder().decode(Component.self, from: data) else { return false }
        return saved.sha256 == component.sha256
    }

    /// Installs the component unless it is already there. Returns its folder.
    @discardableResult
    public func install(_ component: Component) async throws -> URL {
        let destination = home.folder(of: component)
        if isInstalled(component) { return destination }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: home.components, withIntermediateDirectories: true)
        // Work in a fresh folder next to the destination, so the final move is atomic.
        let work = home.components.appendingPathComponent(".tmp-\(component.id)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: work) }

        let archive: URL
        do {
            archive = try await fetch(component.url)
        } catch {
            throw ComponentError.downloadFailed(error.localizedDescription)
        }
        defer { if archive.path.hasPrefix(fileManager.temporaryDirectory.path) { try? fileManager.removeItem(at: archive) } }

        let actual = try Self.sha256(of: archive)
        guard actual == component.sha256.lowercased() else {
            throw ComponentError.checksumMismatch(expected: component.sha256, actual: actual)
        }

        let unpacked = work.appendingPathComponent("unpacked")
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try Self.extract(archive, into: unpacked, members: component.members)

        let root = component.archiveRoot.isEmpty ? unpacked : unpacked.appendingPathComponent(component.archiveRoot)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ComponentError.missingArchiveRoot(component.archiveRoot)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(component).write(to: root.appendingPathComponent(Self.receiptName))

        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: root, to: destination)
        return destination
    }

    /// Lower-case hex SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks with the system `tar` (bsdtar), which reads .tar.xz, .tar.gz and .zip.
    static func extract(_ archive: URL, into folder: URL, members: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", folder.path] + members
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ComponentError.extractionFailed(String(decoding: message, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Default fetcher: a plain HTTPS download to a temporary file.
    @Sendable static func download(_ url: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw ComponentError.downloadFailed("HTTP \(http.statusCode)")
        }
        // URLSession deletes its file when this returns; keep our own copy.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("vitral-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }
}
