import CryptoKit
import Foundation

/// The catalog as published: its exact bytes and their Ed25519 signature, made with Sparkle's
/// release key (`scripts/sign-catalog.sh`). Nobody without that key can change what Vitral reads.
public struct SignedCatalog: Codable, Sendable {
    /// Base64 of `catalog/failures.json`.
    public let catalog: String
    /// Base64 of the signature of those bytes.
    public let signature: String

    public init(catalog: Data, signature: Data) {
        self.catalog = catalog.base64EncodedString()
        self.signature = signature.base64EncodedString()
    }

    /// The catalog, if the signature is valid for `publicKey` (base64, as in `SUPublicEDKey`).
    public func verified(publicKey: String) throws -> FailureCatalog {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let bytes = Data(base64Encoded: catalog), let signature = Data(base64Encoded: signature),
              key.isValidSignature(signature, for: bytes) else { throw CatalogError.badSignature }
        return try FailureCatalog.decode(bytes)
    }
}

/// Where Vitral gets its catalog of failures: the one it came with, or a newer one downloaded from
/// GitHub, so new fixes arrive without a new Vitral (PLAN §13, step 4).
public struct CatalogStore: Sendable {
    /// Sparkle's public key (`SUPublicEDKey`): the catalog is signed with the release key.
    public static let publicKey = "3C1oUZNlIjNaUX3On334bkeR0gXpyS3Raz4VRRZOdD0="
    public static let url = URL(string: "https://raw.githubusercontent.com/noctavox-labs/vitral/main/catalog/failures.signed.json")!
    /// Vitral's own settings, where Sparkle keeps "check for updates automatically".
    static let vitralDefaults = "com.noctavox.vitral"

    public let home: VitralHome
    public let publicKey: String

    public init(home: VitralHome = .default, publicKey: String = CatalogStore.publicKey) {
        self.home = home
        self.publicKey = publicKey
    }

    /// The last catalog downloaded, as it came.
    public var file: URL { home.url.appendingPathComponent("Catalog/failures.signed.json") }

    /// The newest catalog at hand: the downloaded one if its signature holds and it is newer than
    /// the one Vitral came with.
    public func best() -> FailureCatalog {
        guard let downloaded = try? downloaded(), downloaded.revision > FailureCatalog.builtIn.revision else { return .builtIn }
        return downloaded
    }

    /// The downloaded catalog, checked again; nil if there is none.
    public func downloaded() throws -> FailureCatalog? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(SignedCatalog.self, from: Data(contentsOf: file)).verified(publicKey: publicKey)
    }

    /// When Vitral last looked for a new catalog.
    public var lastCheck: Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Whether it is time to look again.
    public func isDue(every interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > interval
    }

    /// Downloads the published catalog and keeps it if the signature holds. Returns the best
    /// catalog afterwards.
    @discardableResult
    public func refresh(timeout: TimeInterval = 15) async throws -> FailureCatalog {
        let request = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw ComponentError.downloadFailed("\(Self.url.absoluteString): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try accept(data)
        return best()
    }

    /// Keeps a signed catalog if it is valid and not older than the one already kept.
    @discardableResult
    public func accept(_ data: Data) throws -> FailureCatalog {
        let catalog = try JSONDecoder().decode(SignedCatalog.self, from: data).verified(publicKey: publicKey)
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let kept = try? downloaded(), kept.revision > catalog.revision {
            // Never go back; just note that Vitral looked.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return kept
        }
        try data.write(to: file, options: .atomic)
        return catalog
    }

    /// Whether the person lets Vitral look for updates by itself. The catalog follows the same
    /// setting ("Check for updates automatically"); it is on unless they turned it off.
    public static var automaticChecks: Bool {
        let defaults = Bundle.main.bundleIdentifier == vitralDefaults ? .standard : UserDefaults(suiteName: vitralDefaults)
        return defaults?.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
    }
}

extension FailureCatalog {
    /// The newest catalog at hand (built in, or downloaded and verified).
    public static var current: FailureCatalog { CatalogStore().best() }
}

/// Fixes that did not help an app, so the launcher does not try them on every opening. Each is
/// tried again once another catalog or engine arrives: it may help then. Kept in the program's
/// folder (`<prefix>/.vitral/`), so it goes away with it.
public struct RepairHistory: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// Tried, and the program still did not open.
        case notEnough
        /// The person did not want it (installing .NET Framework).
        case declined
        /// It could not be applied (a download that failed…).
        case failed
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let revision: Int
        public let engine: String
        public let outcome: Outcome
        public let date: Date
    }

    public var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    public static func url(app: URL, prefix: URL) -> URL {
        prefix.appendingPathComponent(".vitral")
            .appendingPathComponent(Wrapper.safeName(app.deletingPathExtension().lastPathComponent) + " - arreglos probados.json")
    }

    public static func load(from url: URL) -> RepairHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(RepairHistory.self, from: $0) } ?? RepairHistory()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Fixes not to try again with this catalog and engine.
    public func tried(revision: Int, engine: String) -> Set<String> {
        Set(entries.filter { $0.revision == revision && $0.engine == engine }.map(\.key))
    }

    public mutating func record(_ key: String, outcome: Outcome, revision: Int, engine: String, date: Date = Date()) {
        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, revision: revision, engine: engine, outcome: outcome, date: date))
    }

    /// A fix that worked is no longer "tried".
    public mutating func forget(_ key: String) {
        entries.removeAll { $0.key == key }
    }
}
