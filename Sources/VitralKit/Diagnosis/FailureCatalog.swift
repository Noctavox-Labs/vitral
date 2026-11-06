import Foundation

/// Known failures: how each one shows (its signature) and what to do about it. Data, not code, so
/// that later it can be downloaded without a new Vitral (PLAN §13, 2026-11-06). Every entry comes
/// from a real case; `source` says which.
///
/// Published as `catalog/failures.json` (source) and `catalog/failures.signed.json` (signed with
/// Sparkle's release key, what Vitral downloads). Forward compatible: an entry this Vitral cannot
/// read in full (a new kind, a new condition) is left out rather than read in part.
public struct FailureCatalog: Codable, Sendable, Equatable {
    /// The format this Vitral reads. A catalog with a higher one is ignored.
    public static let supportedFormat = 1

    public var format: Int
    /// Grows with every published change (YYYYMMDDnn): the highest wins.
    public var revision: Int
    public var entries: [FailureSignature]

    public init(format: Int = supportedFormat, revision: Int, entries: [FailureSignature]) {
        self.format = format
        self.revision = revision
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case format, revision, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        revision = try c.decode(Int.self, forKey: .revision)
        entries = try c.decode([Lossy<FailureSignature>].self, forKey: .entries).compactMap(\.value)
    }

    /// Reads a catalog. Fails if it is not one, or needs a newer Vitral.
    public static func decode(_ data: Data) throws -> FailureCatalog {
        let catalog = try JSONDecoder().decode(FailureCatalog.self, from: data)
        guard catalog.format <= supportedFormat else { throw CatalogError.newerFormat(catalog.format) }
        return catalog
    }

    /// The catalog that comes with this Vitral.
    public static let builtIn: FailureCatalog = {
        do {
            return try decode(Data(builtInJSON.utf8))
        } catch {
            fatalError("Built-in failure catalog does not decode: \(error)")
        }
    }()

    /// Patterns of the lines that never explain a failure, for log excerpts.
    public var harmless: [String] {
        entries.filter { $0.kind == .harmless }.flatMap { $0.when.flatMap { $0.log ?? [] } }
    }
}

/// One known failure.
public struct FailureSignature: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Vitral knows a fix to try (`fixes`).
        case fixable
        /// It happens now and then; opening it again works.
        case retry
        /// The engine lacks something; a newer engine will bring it.
        case needsNewerEngine
        /// Known not to work yet, and Vitral cannot fix it.
        case notYet
        /// Never works, on purpose (anti-cheat: Vitral never bypasses it).
        case never
        /// Wine prints it for every program; it explains nothing.
        case harmless
    }

    public let id: String
    public let kind: Kind
    public let title: LocalizedText
    public let explanation: LocalizedText
    /// Any of these conditions (each one, all of its parts).
    public let when: [FailureCondition]
    /// What to try, in order: cheapest first.
    public var fixes: [FailureFix] = []
    /// Where it was learned.
    public var source: String?

    enum CodingKeys: String, CodingKey { case id, kind, title, explanation, when, fixes, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(LocalizedText.self, forKey: .title)
        explanation = try c.decodeIfPresent(LocalizedText.self, forKey: .explanation) ?? LocalizedText(es: "", en: "")
        when = try c.decode([FailureCondition].self, forKey: .when)
        fixes = try c.decodeIfPresent([FailureFix].self, forKey: .fixes) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct LocalizedText: Codable, Sendable, Equatable {
    public let es: String
    public let en: String

    public init(es: String, en: String) {
        self.es = es
        self.en = en
    }

    public func text(_ language: Language = .current) -> String { language == .spanish ? es : en }
}

/// Decodes a value, or nil if it cannot (an entry made for a newer Vitral).
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// When a failure applies. Every part given must hold.
public struct FailureCondition: Codable, Sendable, Equatable {
    /// Moments it can happen in; any if absent.
    public var phase: [FailurePhase]?
    /// Regular expressions; any line of the logs matching any of them. The first group of the
    /// match fills `{1}` in the texts.
    public var log: [String]?
    /// Regular expressions that must all match somewhere in the logs.
    public var logAll: [String]?
    /// Exit status of the program.
    public var status: [Int32]?
    /// Whether the program showed a window.
    public var window: Bool?
    /// What the program is built with (`Technology.Kind`), any of them.
    public var technology: [String]?
    /// Regular expression on "product version" or the installer's file name.
    public var product: String?
    /// The engine lacks a function the program imports (`EngineCheck`).
    public var missingFunction: Bool?
    public var antiCheat: Bool?

    public init(phase: [FailurePhase]? = nil, log: [String]? = nil, logAll: [String]? = nil, status: [Int32]? = nil,
                window: Bool? = nil, technology: [String]? = nil, product: String? = nil,
                missingFunction: Bool? = nil, antiCheat: Bool? = nil) {
        self.phase = phase
        self.log = log
        self.logAll = logAll
        self.status = status
        self.window = window
        self.technology = technology
        self.product = product
        self.missingFunction = missingFunction
        self.antiCheat = antiCheat
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case phase, log, logAll, status, window, technology, product, missingFunction, antiCheat
    }

    /// A part this Vitral does not know would be skipped, and the condition would hold more often
    /// than meant: such a condition does not decode.
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = all.allKeys.first(where: { CodingKeys(stringValue: $0.stringValue) == nil }) {
            throw DecodingError.dataCorruptedError(forKey: unknown, in: all, debugDescription: "Unknown condition: \(unknown.stringValue)")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent([FailurePhase].self, forKey: .phase)
        log = try c.decodeIfPresent([String].self, forKey: .log)
        logAll = try c.decodeIfPresent([String].self, forKey: .logAll)
        status = try c.decodeIfPresent([Int32].self, forKey: .status)
        window = try c.decodeIfPresent(Bool.self, forKey: .window)
        technology = try c.decodeIfPresent([String].self, forKey: .technology)
        product = try c.decodeIfPresent(String.self, forKey: .product)
        missingFunction = try c.decodeIfPresent(Bool.self, forKey: .missingFunction)
        antiCheat = try c.decodeIfPresent(Bool.self, forKey: .antiCheat)
    }
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case newerFormat(Int)
    case badSignature
    case notSigned

    public var description: String {
        switch self {
        case .newerFormat(let format):
            return tr("El catálogo necesita un Vitral más nuevo (formato \(format)).", "The catalog needs a newer Vitral (format \(format)).")
        case .badSignature: return tr("La firma del catálogo no es válida.", "The catalog's signature is not valid.")
        case .notSigned: return tr("El catálogo no está firmado.", "The catalog is not signed.")
        }
    }
}

public enum FailurePhase: String, Codable, Sendable {
    /// Before installing: only what the installer shows (name, version).
    case analysis
    case install
    /// It closed while opening, without a window.
    case start
    /// It opened; the person says something does not work.
    case running
}

/// One thing to try. Only one field is set; a fix with a field this Vitral does not know does not
/// decode, and its entry is left out.
public struct FailureFix: Codable, Sendable, Equatable {
    /// One of `Recipes`' rules.
    public var recipe: String?
    public var environment: [String: String]?
    public var arguments: [String]?
    /// A component to install, such as "dotnet48".
    public var component: String?
    /// "newer": an engine with what this one lacks.
    public var engine: String?
    public var retry: Bool?

    public init(recipe: String? = nil, environment: [String: String]? = nil, arguments: [String]? = nil,
                component: String? = nil, engine: String? = nil, retry: Bool? = nil) {
        self.recipe = recipe
        self.environment = environment
        self.arguments = arguments
        self.component = component
        self.engine = engine
        self.retry = retry
    }

    enum CodingKeys: String, CodingKey { case recipe, environment, arguments, component, engine, retry }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = all.allKeys.first(where: { CodingKeys(stringValue: $0.stringValue) == nil }) {
            throw DecodingError.dataCorruptedError(forKey: unknown, in: all, debugDescription: "Unknown fix: \(unknown.stringValue)")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipe = try c.decodeIfPresent(String.self, forKey: .recipe)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments)
        component = try c.decodeIfPresent(String.self, forKey: .component)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        retry = try c.decodeIfPresent(Bool.self, forKey: .retry)
    }
}
