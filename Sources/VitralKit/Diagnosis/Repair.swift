import Foundation

/// A fix from the catalog that Vitral can try by itself when a program does not open. Only
/// closed, reversible levers: settings (variables, registry, arguments, files to clean) and
/// Microsoft components pinned by checksum. Never code from outside Vitral.
public struct Repair: Sendable, Equatable {
    public let diagnosis: Diagnosis
    public let fix: FailureFix
    /// Unique per fix: "qt-opengl#1".
    public let key: String
    /// What it does, in words.
    public let description: String
    /// The program's settings with the fix, for settings fixes.
    public let settings: LaunchSettings?
    /// A component to install, such as "dotnet48".
    public let component: String?
    /// What the manifest lists once the fix works.
    public let recipe: AppliedRecipe

    /// Whether trying it changes the program's files or registry (and so needs a copy to go back).
    public var changesPrefix: Bool { component != nil || !(settings?.registry.isEmpty ?? true) }
}

public enum RepairPlanner {
    /// Fixes tried in one opening, at most.
    public static let maxRepairs = 3
    /// Components Vitral knows how to install.
    static let components: Set<String> = ["dotnet48"]

    /// The fixes to try for what was seen, in the catalog's order: leaves out the ones already in
    /// place, the ones in `tried`, and what Vitral cannot do by itself.
    public static func plan(_ diagnoses: [Diagnosis], settings current: LaunchSettings, prefix: URL,
                            tried: Set<String> = [], language: Language = .current) -> [Repair] {
        var repairs: [Repair] = []
        for diagnosis in diagnoses where diagnosis.kind == .fixable {
            for (index, fix) in diagnosis.signature.fixes.enumerated() {
                let key = "\(diagnosis.id)#\(index)"
                guard !tried.contains(key) else { continue }
                let description = describe(fix, language: language)
                if let component = fix.component {
                    guard components.contains(component), !DotNetFramework.isInstalled(prefix: prefix) else { continue }
                    repairs.append(Repair(diagnosis: diagnosis, fix: fix, key: key, description: description, settings: nil,
                                          component: component,
                                          recipe: DotNetFramework.recipe(because: diagnosis.id)))
                } else if let settings = settings(with: fix, from: current) {
                    repairs.append(Repair(diagnosis: diagnosis, fix: fix, key: key, description: description,
                                          settings: settings, component: nil,
                                          recipe: AppliedRecipe(id: fix.recipe ?? diagnosis.id, because: diagnosis.id)))
                }
            }
        }
        return repairs
    }

    /// `current` with the fix, or nil if it is not a settings fix or is already there. Variables
    /// Wine does not pass from the Mac (`QT_…`) go in the registry, where Windows programs see them.
    public static func settings(with fix: FailureFix, from current: LaunchSettings) -> LaunchSettings? {
        var fragment = LaunchSettings()
        if let recipe = fix.recipe {
            guard let settings = Recipes.fragment(recipe) else { return nil }
            fragment = settings
        }
        for (name, value) in (fix.environment ?? [:]).sorted(by: { $0.key < $1.key }) {
            if WineSession.reachesWindows(name) {
                fragment.environment[name] = value
            } else {
                fragment.registry.append(.string(Recipes.windowsEnvironment, name, value))
            }
        }
        fragment.arguments += fix.arguments ?? []
        guard fragment != LaunchSettings() else { return nil }
        let result = current.adding(fragment)
        return result == current ? nil : result
    }

    /// Settings for a program the catalog knows by name: an entry that can be fixed and matches
    /// before installing (`phase: analysis`, `product`). Its first settings fix goes in when the app
    /// is made, so the program opens well the first time. `names` are the installer's file name
    /// and the program's name and version.
    public static func knownProgram(names: [String], settings: LaunchSettings,
                                    catalog: FailureCatalog = .current) -> (settings: LaunchSettings, applied: [AppliedRecipe]) {
        var settings = settings
        var applied: [AppliedRecipe] = []
        let diagnoses = Diagnoser.diagnose(FailureObservation(phase: .analysis, names: names), catalog: catalog)
        for diagnosis in diagnoses where diagnosis.kind == .fixable {
            for fix in diagnosis.signature.fixes {
                guard let changed = Self.settings(with: fix, from: settings) else { continue }
                settings = changed
                applied.append(AppliedRecipe(id: fix.recipe ?? diagnosis.id, because: diagnosis.id))
                break
            }
        }
        return (settings, applied)
    }

    /// The names a program is known by: "Paint.NET 5.1.12", its file description, the installer.
    public static func names(of product: VersionInfo?, installer: String?) -> [String] {
        var names: [String] = []
        if let installer { names.append(installer) }
        if let product {
            for name in [product.productName, product.fileDescription].compactMap({ $0 }) {
                names.append([name, product.productVersion].compactMap { $0 }.joined(separator: " "))
            }
        }
        return names
    }

    static func describe(_ fix: FailureFix, language: Language) -> String {
        if let recipe = fix.recipe { return Recipes.describe(recipe, language: language) }
        if fix.component == "dotnet48" { return Recipes.describe("dotnet-framework-4.8", language: language) }
        if let environment = fix.environment {
            return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        return (fix.arguments ?? []).joined(separator: " ")
    }
}

/// A copy of a program's files to go back to when a fix does not help. On APFS the copy takes no
/// space until something changes.
public struct PrefixBackup: Sendable {
    public enum Scope: Sendable {
        /// Only the registry (`system.reg`, `user.reg`, `userdef.reg`).
        case registry
        /// The whole prefix (for a component).
        case everything
    }

    public let prefix: URL
    public let copy: URL
    public let scope: Scope

    static let registryFiles = ["system.reg", "user.reg", "userdef.reg"]

    /// Where the copies go: next to the prefixes, so the copy is a clone.
    static func folder(_ home: VitralHome) -> URL { home.url.appendingPathComponent("Staging") }
    static func namePrefix(_ prefix: URL) -> String { "Copia - " + prefix.lastPathComponent + " - " }

    /// Copies the prefix's registry, or all of it. Wine must not be running for it.
    public static func make(of prefix: URL, scope: Scope, home: VitralHome = .default) throws -> PrefixBackup {
        let fm = FileManager.default
        let folder = folder(home)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(namePrefix(prefix) + UUID().uuidString.prefix(8))
        switch scope {
        case .registry:
            try fm.createDirectory(at: copy, withIntermediateDirectories: false)
            for name in registryFiles where fm.fileExists(atPath: prefix.appendingPathComponent(name).path) {
                try fm.copyItem(at: prefix.appendingPathComponent(name), to: copy.appendingPathComponent(name))
            }
        case .everything:
            // One call clones the whole tree, links included (not followed).
            guard clonefile(prefix.path, copy.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: copy.path,
                                                               NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
        }
        return PrefixBackup(prefix: prefix, copy: copy, scope: scope)
    }

    /// Puts the copy back in place of what changed, and removes it. Wine must not be running.
    public func restore() throws {
        let fm = FileManager.default
        switch scope {
        case .registry:
            for name in Self.registryFiles {
                let current = prefix.appendingPathComponent(name), saved = copy.appendingPathComponent(name)
                guard fm.fileExists(atPath: saved.path) else { continue }
                _ = try fm.replaceItemAt(current, withItemAt: saved)
            }
            try? fm.removeItem(at: copy)
        case .everything:
            let aside = copy.deletingLastPathComponent().appendingPathComponent(copy.lastPathComponent + " (deshecho)")
            try fm.moveItem(at: prefix, to: aside)
            do {
                try fm.moveItem(at: copy, to: prefix)
            } catch {
                try? fm.moveItem(at: aside, to: prefix)
                throw error
            }
            try? fm.removeItem(at: aside)
        }
    }

    /// The fix stays: the copy is no longer needed.
    public func discard() {
        try? FileManager.default.removeItem(at: copy)
    }

    /// Copies of `prefix` left by an opening that did not finish (the Mac shut down mid-try).
    public static func leftovers(of prefix: URL, home: VitralHome = .default) -> [URL] {
        let folder = folder(home)
        let start = namePrefix(prefix)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(start) }.map { folder.appendingPathComponent($0) }
    }
}
