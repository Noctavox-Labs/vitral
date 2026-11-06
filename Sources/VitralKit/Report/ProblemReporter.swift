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

        return finish(ProblemReport(kind: .install(message), productName: productName,
                                    program: productName + (version?.productVersion.map { " " + $0 } ?? ""),
                                    mac: describe(mac), facts: facts, log: [], logFile: log), privacy: privacy)
    }

    /// For an app made by Vitral: it closed while opening after `attempts`, or (nil) the person
    /// reports something that does not work.
    public static func app(_ app: URL, closedWhileOpening attempts: Int? = nil, home: VitralHome = .default,
                           mac: MacInfo = .current(), privacy: PrivateData = .current) -> ProblemReport {
        let wrapper = Wrapper(url: app)
        let name = app.deletingPathExtension().lastPathComponent
        let log = ProgramInstaller.logs.appendingPathComponent(Wrapper.safeName(name) + ".log")
        let kind: ProblemReport.Kind = attempts.map { .start(attempts: $0) } ?? .other
        guard let manifest = try? wrapper.readManifest() else {
            return finish(ProblemReport(kind: kind, productName: name, program: name, mac: describe(mac),
                                        facts: [], log: [], logFile: log), privacy: privacy)
        }
        let product = manifest.product
        let productName = product?.productName ?? manifest.name
        let prefix = wrapper.prefix(in: home)
        let program = prefix.appendingPathComponent("drive_c").appendingPathComponent(manifest.program)
        var facts: [ProblemReport.Fact] = [.init(tr("Programa", "Program"), manifest.program)]
        if let publisher = product?.companyName { facts.append(.init(tr("Editor", "Publisher"), publisher)) }
        if let installer = manifest.installer {
            facts.append(.init(tr("Instalador", "Installer"), installer + (manifest.installerSHA256.map { " · SHA-256 " + $0 } ?? "")))
        }

        if let analysis = try? ProgramAnalyzer.analyze(folderAt: program.deletingLastPathComponent(),
                                                       preferring: program.lastPathComponent) {
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
        let companions = Uninstaller.companions(of: app).map { $0.deletingPathExtension().lastPathComponent }
        if !companions.isEmpty {
            facts.append(.init(tr("Del mismo instalador", "From the same installer"), companions.joined(separator: ", ")))
        }
        if let engine = EngineCatalog.engine(id: manifest.engine) {
            let missing = EngineCheck.missingImports(program: program, engine: InstalledEngine(engine: engine, home: home), prefix: prefix)
            if !missing.isEmpty {
                facts.append(.init(tr("Le falta al motor", "Missing in the engine"), MissingImport.summary(missing, limit: 6)))
            }
        }
        facts.append(.init(tr("App creada con", "App made with"), manifest.createdWith))

        return finish(ProblemReport(kind: kind, productName: productName,
                                    program: productName + (product?.productVersion.map { " " + $0 } ?? ""),
                                    mac: describe(mac), facts: facts, log: [], logFile: log), privacy: privacy)
    }

    /// Adds the log's useful lines and takes personal data out of everything.
    static func finish(_ report: ProblemReport, privacy: PrivateData) -> ProblemReport {
        var report = report
        if let file = report.logFile, FileManager.default.fileExists(atPath: file.path) {
            report.log = LogExcerpt.lines(of: LogExcerpt.read(file)).map(privacy.redact)
        }
        report.facts = report.facts.map { .init($0.label, privacy.redact($0.value)) }
        report.program = privacy.redact(report.program)
        report.productName = privacy.redact(report.productName)
        if case .install(let message) = report.kind { report.kind = .install(privacy.redact(message)) }
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
