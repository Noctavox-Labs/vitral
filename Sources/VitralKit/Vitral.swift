import Foundation

/// Project-wide constants.
public enum Vitral {
    public static let version = "0.1.7"
}

/// Languages Vitral speaks. The user interface is always bilingual (Spanish and English).
public enum Language: String, Sendable, CaseIterable {
    case spanish = "es"
    case english = "en"

    /// The language to use: `VITRAL_LANG` (es/en) if set, otherwise the first of the
    /// user's preferred macOS languages that Vitral supports, otherwise English.
    public static var current: Language {
        if let forced = ProcessInfo.processInfo.environment["VITRAL_LANG"],
           let language = Language(rawValue: forced.lowercased()) {
            return language
        }
        for identifier in Locale.preferredLanguages {
            if identifier.hasPrefix("es") { return .spanish }
            if identifier.hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// Picks the Spanish or English text. A stopgap until the app moves to String Catalogs.
public func tr(_ spanish: String, _ english: String, _ language: Language = .current) -> String {
    language == .spanish ? spanish : english
}
