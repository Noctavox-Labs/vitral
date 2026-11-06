import Foundation

/// Gathers what a report needs: about the Mac, the installer or app, and its log.
/// Reads files (and may hash a large installer): call it off the main thread.
public enum ProblemReporter {
    /// For an installation that stopped with `message`. `log` is the installation's log, if it
    /// got that far.
    public static func installation(_ installer: URL, message: String, log: URL?,
                                    mac: MacInfo = .current(), privacy: PrivateData = .current) -> ProblemReport {
        let report = try? InstallerAnalyzer.analyze(fileAt: installer)
        let version = report?.executable?.version
        let productName = version?.productName ?? version?.fileDescription ?? installer.deletingPathExtension().lastPathComponent
        var facts: [ProblemReport.Fact] = []

        var file = installer.lastPathComponent
        if let report { file += " · " + ByteCountFormatter.string(fromByteCount: report.sizeBytes, countStyle: .file) }
        if let hash = try? ComponentInstaller.sha256(of: installer) { file += " · SHA-256 " + hash }
        facts.append(.init(tr("Instalador", "Installer"), file))
        if let report {
            var kind = report.kind.rawValue + (report.kindVersion.map { " " + $0 } ?? "")
            if let builder = report.builder { kind += " (\(builder.rawValue))" }
            if let executable = report.executable { kind += " · \(executable.bits) bits" }
            facts.append(.init(tr("Tipo", "Type"), kind))
            if let bits = report.programBits { facts.append(.init(tr("Programa", "Program"), "\(bits) bits")) }
        }
        if let publisher = version?.companyName { facts.append(.init(tr("Editor", "Publisher"), publisher)) }
        facts.append(.init(tr("Motor", "Engine"), EngineCatalog.default.id))

        var problem = ProblemReport(kind: .install(message), productName: productName,
                                    program: productName + (version?.productVersion.map { " " + $0 } ?? ""),
                                    mac: describe(mac), facts: facts, log: [], logFile: log)
        problem.diagnoses = Diagnoser.diagnose(.installation(report, fileName: installer.lastPathComponent, message: message, log: log),
                                               catalog: .current)
        return finish(problem, privacy: privacy)
    }

    /// For an app made by Vitral: it closed while opening after `attempts`, or (nil) the person
    /// reports something that does not work.
    public static func app(_ app: URL, closedWhileOpening attempts: Int? = nil, home: VitralHome = .default,
                           mac: MacInfo = .current(), privacy: PrivateData = .current) -> ProblemReport {
        let inspection = AppInspection(app: app, phase: attempts == nil ? .running : .start, home: home)
        return Self.app(inspection, closedWhileOpening: attempts, mac: mac, privacy: privacy)
    }

    public static func app(_ inspection: AppInspection, closedWhileOpening attempts: Int? = nil,
                           mac: MacInfo = .current(), privacy: PrivateData = .current) -> ProblemReport {
        let name = inspection.app.deletingPathExtension().lastPathComponent
        var kind: ProblemReport.Kind = attempts.map { .start(attempts: $0) } ?? .other
        // It said why in its own words (Encarta 2009's "Application cannot start").
        if let run = inspection.lastRun, run.errorBox, let box = run.messageBoxes.last { kind = .errorBox(box.summary) }
        guard let manifest = inspection.manifest, let prefix = inspection.prefix else {
            return finish(ProblemReport(kind: kind, productName: name, program: name, mac: describe(mac),
                                        facts: [], log: [], logFile: inspection.launchLog), privacy: privacy)
        }
        let product = manifest.product
        let productName = product?.productName ?? manifest.name
        var facts: [ProblemReport.Fact] = [.init(tr("Programa", "Program"), manifest.program)]
        // What the program itself said before closing (the summary has the last one).
        if let boxes = inspection.lastRun?.messageBoxes, boxes.count > 1 || inspection.lastRun?.errorBox == false, !boxes.isEmpty {
            facts.append(.init(tr("Mensaje de error", "Error message"), boxes.suffix(2).map { "«\($0.summary)»" }.joined(separator: " · ")))
        }
        if let publisher = product?.companyName { facts.append(.init(tr("Editor", "Publisher"), publisher)) }
        if let installer = manifest.installer {
            facts.append(.init(tr("Instalador", "Installer"), installer + (manifest.installerSHA256.map { " · SHA-256 " + $0 } ?? "")))
        }
        if let analysis = inspection.analysis {
            var made: [String] = analysis.executable.map { ["\($0.bits) bits"] } ?? []
            made += analysis.technologies.map { $0.kind.rawValue + ($0.version.map { " " + $0 } ?? "") }
            made += analysis.graphics.map(\.rawValue)
            facts.append(.init(tr("Hecho con", "Built with"), made.joined(separator: ", ")))
            if !analysis.antiCheat.isEmpty {
                facts.append(.init(tr("Antitrampas", "Anti-cheat"), analysis.antiCheat.map(\.rawValue).joined(separator: ", ")))
            }
        }
        facts.append(.init(tr("Motor", "Engine"), manifest.engine))
        if !manifest.recipes.isEmpty {
            facts.append(.init(tr("Recetas", "Recipes"), manifest.recipes.map(\.id).joined(separator: ", ")))
        }
        let settings = manifest.settings.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            + manifest.settings.arguments
        if !settings.isEmpty { facts.append(.init(tr("Ajustes", "Settings"), settings.joined(separator: " "))) }
        if DotNetFramework.isInstalled(prefix: prefix) { facts.append(.init(".NET Framework", "4.8")) }
        let companions = Uninstaller.companions(of: inspection.app).map { $0.deletingPathExtension().lastPathComponent }
        if !companions.isEmpty {
            facts.append(.init(tr("Del mismo instalador", "From the same installer"), companions.joined(separator: ", ")))
        }
        if !inspection.missing.isEmpty {
            facts.append(.init(tr("Le falta al motor", "Missing in the engine"), MissingImport.summary(inspection.missing, limit: 6)))
        }
        facts.append(.init(tr("App creada con", "App made with"), manifest.createdWith))

        var report = ProblemReport(kind: kind, productName: productName,
                                   program: productName + (product?.productVersion.map { " " + $0 } ?? ""),
                                   mac: describe(mac), facts: facts, log: [], logFile: inspection.launchLog)
        report.programLogs = inspection.programLogs
        report.diagnoses = inspection.diagnoses()
        return finish(report, privacy: privacy)
    }

    /// Adds the log's useful lines and takes personal data out of everything.
    static func finish(_ report: ProblemReport, privacy: PrivateData) -> ProblemReport {
        var report = report
        var lines: [String] = []
        if let file = report.logFile, FileManager.default.fileExists(atPath: file.path) {
            lines = LogExcerpt.lines(of: LogExcerpt.read(file), catalog: .current)
        }
        // The program's own logs, each line marked with its file.
        for file in report.programLogs {
            let text = LogExcerpt.read(file, head: 64 * 1024, tail: 256 * 1024)
            lines += LogExcerpt.lines(of: text, limit: 20, catalog: .current).map { "[\(file.lastPathComponent)] \($0)" }
        }
        report.log = lines.map(privacy.redact)
        // What Vitral recognized goes first: it is what a reader needs.
        let known = report.diagnoses.prefix(3).map { diagnosis in
            ProblemReport.Fact(tr("Diagnóstico", "Diagnosis"), "\(diagnosis.title) [\(diagnosis.id)]")
        }
        report.facts = known + report.facts
        report.facts = report.facts.map { .init($0.label, privacy.redact($0.value)) }
        report.program = privacy.redact(report.program)
        report.productName = privacy.redact(report.productName)
        if case .install(let message) = report.kind { report.kind = .install(privacy.redact(message)) }
        if case .errorBox(let message) = report.kind { report.kind = .errorBox(privacy.redact(message)) }
        return report
    }

    /// "MacBookPro18,3 · Apple M1 Pro · 16 GB · macOS 27.2 · Rosetta"
    public static func describe(_ mac: MacInfo) -> String {
        var parts: [String] = []
        if let model = MacInfo.model { parts.append(model) }
        parts.append(mac.chip)
        parts.append("\(mac.memoryBytes / 1_073_741_824) GB")
        parts.append("macOS " + mac.macOSVersionText)
        parts.append(mac.hasRosetta ? "Rosetta" : tr("sin Rosetta", "no Rosetta"))
        return parts.joined(separator: " · ")
    }
}
