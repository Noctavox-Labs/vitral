import Foundation

/// What Vitral saw when something went wrong, to compare with the catalog.
public struct FailureObservation: Sendable, Equatable {
    public var phase: FailurePhase
    /// Wine's log and the program's own logs, as text.
    public var logs: [String]
    public var status: Int32?
    public var sawWindow: Bool?
    /// "Paint.NET 5.1.12", the installer's file name…: what `product` conditions look at.
    public var names: [String]
    /// `Technology.Kind` raw values.
    public var technologies: [String]
    public var antiCheat: Bool
    /// The engine lacks a function the program imports.
    public var missingFunction: Bool

    public init(phase: FailurePhase, logs: [String] = [], status: Int32? = nil, sawWindow: Bool? = nil,
                names: [String] = [], technologies: [String] = [], antiCheat: Bool = false, missingFunction: Bool = false) {
        self.phase = phase
        self.logs = logs
        self.status = status
        self.sawWindow = sawWindow
        self.names = names
        self.technologies = technologies
        self.antiCheat = antiCheat
        self.missingFunction = missingFunction
    }
}

/// A known failure found in an observation.
public struct Diagnosis: Sendable, Equatable {
    public let signature: FailureSignature
    public let title: String
    public let explanation: String
    /// The log line that matched, if a line did.
    public let evidence: String?

    public var id: String { signature.id }
    public var kind: FailureSignature.Kind { signature.kind }

    /// What Vitral can try, in words: "Electron draws inside the program…", "a newer engine".
    public var fixesText: [String] {
        signature.fixes.map { fix in
            if let recipe = fix.recipe { return Recipes.describe(recipe) }
            if let environment = fix.environment {
                return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            }
            if let arguments = fix.arguments { return arguments.joined(separator: " ") }
            if fix.component == "dotnet48" { return Recipes.describe("dotnet-framework-4.8") }
            if let component = fix.component { return component }
            if fix.engine != nil { return tr("un motor más nuevo", "a newer engine") }
            if fix.retry == true { return tr("volver a abrirlo", "opening it again") }
            return ""
        }.filter { !$0.isEmpty }
    }
}

/// Compares what happened with the known failures.
public enum Diagnoser {
    /// The known failures that match, most specific first (the catalog's order). Harmless lines
    /// are left out.
    public static func diagnose(_ observation: FailureObservation, catalog: FailureCatalog = .builtIn,
                                language: Language = .current) -> [Diagnosis] {
        let text = observation.logs.joined(separator: "\n") as NSString
        var cache: [String: NSRegularExpression] = [:]
        func regex(_ pattern: String) -> NSRegularExpression? {
            if let compiled = cache[pattern] { return compiled }
            let compiled = try? NSRegularExpression(pattern: pattern)
            cache[pattern] = compiled
            return compiled
        }
        var found: [Diagnosis] = []
        for entry in catalog.entries where entry.kind != .harmless {
            for condition in entry.when {
                guard let match = matches(condition, observation, text: text, regex: regex) else { continue }
                let fill = { (s: String) in s.replacingOccurrences(of: "{1}", with: match.capture ?? "?") }
                found.append(Diagnosis(signature: entry, title: fill(entry.title.text(language)),
                                       explanation: fill(entry.explanation.text(language)), evidence: match.evidence))
                break
            }
        }
        return found
    }

    /// Whether `condition` holds; with the matching log line and its first group.
    static func matches(_ condition: FailureCondition, _ o: FailureObservation, text: NSString,
                        regex: (String) -> NSRegularExpression?) -> (evidence: String?, capture: String?)? {
        if let phases = condition.phase, !phases.contains(o.phase) { return nil }
        if let statuses = condition.status {
            guard let status = o.status, statuses.contains(status) else { return nil }
        }
        if let window = condition.window, o.sawWindow != window { return nil }
        if let kinds = condition.technology, !kinds.contains(where: o.technologies.contains) { return nil }
        if let product = condition.product {
            guard let pattern = regex(product), o.names.contains(where: {
                pattern.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
            }) else { return nil }
        }
        if let missing = condition.missingFunction, o.missingFunction != missing { return nil }
        if let antiCheat = condition.antiCheat, o.antiCheat != antiCheat { return nil }
        let whole = NSRange(location: 0, length: text.length)
        if let all = condition.logAll {
            for pattern in all {
                guard let compiled = regex(pattern), compiled.firstMatch(in: text as String, range: whole) != nil else { return nil }
            }
        }
        guard let any = condition.log else { return (nil, nil) }
        // The earliest line that matches any of the patterns.
        var best: NSTextCheckingResult?
        for pattern in any {
            guard let match = regex(pattern)?.firstMatch(in: text as String, range: whole) else { continue }
            if best == nil || match.range.location < best!.range.location { best = match }
        }
        guard let best else { return nil }
        let line = text.substring(with: text.lineRange(for: best.range)).trimmingCharacters(in: .whitespacesAndNewlines)
        let capture = best.numberOfRanges > 1 && best.range(at: 1).location != NSNotFound
            ? text.substring(with: best.range(at: 1)) : nil
        return (String(line.prefix(300)), capture)
    }
}

/// Reads what the launcher wrote about the last time the program was opened.
public enum LaunchLog {
    public struct Run: Sendable, Equatable {
        public let seconds: Int
        public let status: Int32
        public let sawWindow: Bool
    }

    /// The last "Ended after 13 s (status 3, window: no)" line, in English or Spanish.
    public static func lastRun(in text: String) -> Run? {
        let pattern = #"(?:Ended after|Terminó a los) (\d+) s \((?:status|código) (-?\d+), (?:window|ventana): (yes|no|sí|si)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let seconds = Int(ns.substring(with: match.range(at: 1))),
              let status = Int32(ns.substring(with: match.range(at: 2))) else { return nil }
        return Run(seconds: seconds, status: status, sawWindow: ns.substring(with: match.range(at: 3)) != "no")
    }

    /// Whether that run was a failed start (as the launcher decides it).
    public static func failedToStart(_ run: Run) -> Bool {
        !run.sawWindow && TimeInterval(run.seconds) < StartupWatch.startupWindow && run.status != 0
    }
}

/// Logs the program itself writes (Shape It!'s `AppData/Local/Avallain/…/appLogs.txt` was the key
/// to its Qt failures, which Wine's log never showed).
public enum ProgramLogs {
    /// Folders full of files that are never logs (Chromium's caches).
    static let skipped: Set<String> = ["Cache", "Code Cache", "GPUCache", "Service Worker", "IndexedDB",
                                       "blob_storage", "Crashpad", "DawnCache", "GrShaderCache", "ShaderCache"]

    /// Log files written since `date` in the prefix's AppData and ProgramData and in the program's
    /// folder, newest first. Never follows links (the prefix links to the person's folders).
    public static func written(since date: Date, prefix: URL, programFolder: URL? = nil, limit: Int = 6) -> [URL] {
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c")
        var roots = [driveC.appendingPathComponent("ProgramData")]
        let users = driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            roots.append(users.appendingPathComponent(user).appendingPathComponent("AppData"))
        }
        if let programFolder { roots.append(programFolder) }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var found: [(URL, Date)] = []
        var visited = 0
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > 30_000 { break }
                // The walker does not go into links; a link to a file is skipped too.
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, let modified = values.contentModificationDate, modified >= date,
                      let size = values.fileSize, size > 0, size < 64 * 1024 * 1024, isLogName(url.lastPathComponent)
                else { continue }
                found.append((url, modified))
            }
        }
        // Each file once (the program's folder can be inside ProgramData).
        var seen: Set<String> = []
        return found.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.standardizedFileURL.path).inserted }.prefix(limit).map { $0 }
    }

    static func isLogName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".log") || lower.hasSuffix(".txt") && lower.contains("log")
    }
}

/// Everything Vitral can tell about an app made by Vitral and its last run.
public struct AppInspection: Sendable {
    public let app: URL
    public let manifest: WrapperManifest?
    public let prefix: URL?
    public let program: URL?
    public let analysis: ProgramReport?
    public let missing: [MissingImport]
    /// The launcher's log (Wine's output included).
    public let launchLog: URL
    /// Logs the program wrote since it was last opened.
    public let programLogs: [URL]
    public let lastRun: LaunchLog.Run?
    public let observation: FailureObservation

    /// `phase` is `.start` when the launcher saw it close while opening, `.running` when the person
    /// reports something, or found from the log when not given.
    public init(app: URL, phase: FailurePhase? = nil, home: VitralHome = .default) {
        let fm = FileManager.default
        let wrapper = Wrapper(url: app)
        let name = app.deletingPathExtension().lastPathComponent
        self.app = app
        launchLog = ProgramInstaller.logs.appendingPathComponent(Wrapper.safeName(name) + ".log")
        let wineLog = fm.fileExists(atPath: launchLog.path) ? LogExcerpt.read(launchLog) : ""
        lastRun = LaunchLog.lastRun(in: wineLog)

        manifest = try? wrapper.readManifest()
        var names = [name]
        var technologies: [String] = []
        var antiCheat = false
        if let manifest {
            let prefix = wrapper.prefix(in: home)
            let program = prefix.appendingPathComponent("drive_c").appendingPathComponent(manifest.program)
            self.prefix = prefix
            self.program = program
            analysis = try? ProgramAnalyzer.analyze(folderAt: program.deletingLastPathComponent(), preferring: program.lastPathComponent)
            if let engine = EngineCatalog.engine(id: manifest.engine) {
                missing = EngineCheck.missingImports(program: program, engine: InstalledEngine(engine: engine, home: home), prefix: prefix)
            } else {
                missing = []
            }
            // The launcher makes its log when it opens the program: what the program wrote since.
            let opened = (try? launchLog.resourceValues(forKeys: [.creationDateKey]).creationDate)
            programLogs = opened.map { ProgramLogs.written(since: $0, prefix: prefix, programFolder: program.deletingLastPathComponent()) } ?? []
            if let product = manifest.product {
                names.append([product.productName ?? manifest.name, product.productVersion].compactMap { $0 }.joined(separator: " "))
            }
            if let installer = manifest.installer { names.append(installer) }
            technologies = analysis?.technologies.map(\.kind.rawValue) ?? []
            antiCheat = !(analysis?.antiCheat.isEmpty ?? true)
        } else {
            prefix = nil
            program = nil
            analysis = nil
            missing = []
            programLogs = []
        }

        let resolved = phase ?? (lastRun.map(LaunchLog.failedToStart) == true ? .start : .running)
        observation = FailureObservation(
            phase: resolved,
            logs: [wineLog] + programLogs.map { LogExcerpt.read($0, head: 64 * 1024, tail: 256 * 1024) },
            status: lastRun?.status, sawWindow: lastRun?.sawWindow, names: names, technologies: technologies,
            antiCheat: antiCheat, missingFunction: missing.contains { $0.function != nil })
    }

    public func diagnoses(catalog: FailureCatalog = .builtIn) -> [Diagnosis] {
        Diagnoser.diagnose(observation, catalog: catalog)
    }
}

extension FailureObservation {
    /// Before installing: only the installer's name and version.
    public static func analysis(_ report: InstallerReport) -> FailureObservation {
        FailureObservation(phase: .analysis, names: names(of: report))
    }

    /// An installation that stopped: its message and log.
    public static func installation(_ report: InstallerReport?, fileName: String, message: String?, log: URL?) -> FailureObservation {
        var logs: [String] = []
        if let log, FileManager.default.fileExists(atPath: log.path) { logs.append(LogExcerpt.read(log)) }
        if let message { logs.append(message) }
        return FailureObservation(phase: .install, logs: logs, names: report.map(names(of:)) ?? [fileName])
    }

    static func names(of report: InstallerReport) -> [String] {
        var names = [report.fileName]
        if let version = report.executable?.version {
            let product = [version.productName ?? version.fileDescription, version.productVersion].compactMap { $0 }
            if !product.isEmpty { names.append(product.joined(separator: " ")) }
        }
        return names
    }
}
