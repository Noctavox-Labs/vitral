import Foundation

/// Steps of an installation, for progress messages.
public enum InstallStage: Sendable, Equatable {
    case checking
    case downloadingEngine(Double)
    case preparingWindows
    /// The installer is open: the person follows its steps. With what it is doing, when its
    /// processes say it ("Installing MSXML 6…", `InstallerActivity`).
    case runningInstaller(String? = nil)
    /// The installer ended; something it started is still running (the program, a helper).
    case finishingInstaller
    /// The installer opened the program ("Launch …" checked): Vitral closes that copy.
    case closingProgram
    /// A ZIP or a program that is not an installer: copied in, nothing to click.
    case copyingProgram
    case findingProgram
    case applyingSettings
    /// Installing Microsoft's .NET Framework 4.8 into the prefix (about five minutes).
    case installingDotNet(Double)
    /// Putting Wine Gecko into the prefix: the program shows pages with Internet Explorer's
    /// control (a download of about 43 MB the first time).
    case installingBrowser(Double)
    case buildingApp

    public var isRunningInstaller: Bool {
        if case .runningInstaller = self { return true }
        return false
    }
}

public enum InstallError: Error, CustomStringConvertible {
    case unsupported(String)
    case rosettaMissing
    case launcherMissing
    case programNotFound(log: URL)
    case installerDidNotStart(Int32, log: URL)
    case prerequisiteLoop(String, log: URL)
    case windowsInUse(String)
    case sharedWindowsMissing
    case dotNetFailed(release: Int?)
    case installerStopped(String, log: URL)

    public var description: String {
        switch self {
        case .unsupported(let reason):
            return reason
        case .rosettaMissing:
            return tr("Falta Rosetta, y Wine la necesita. Instálala desde la app Vitral o con: softwareupdate --install-rosetta",
                      "Rosetta is missing and Wine needs it. Install it from the Vitral app or with: softwareupdate --install-rosetta")
        case .launcherMissing:
            return tr("No encuentro el lanzador (vitral-launcher). Compila todo con: swift build",
                      "The launcher (vitral-launcher) is missing. Build everything with: swift build")
        case .programNotFound(let log):
            return tr("El instalador terminó, pero no encontré ningún programa nuevo. ¿Se canceló la instalación? Registro: \(log.path)",
                      "The installer finished, but I found no new program. Was the installation cancelled? Log: \(log.path)")
        case .installerDidNotStart(let status, let log):
            return tr("El instalador no pudo abrirse (código \(status)). Registro: \(log.path)",
                      "The installer could not start (status \(status)). Log: \(log.path)")
        case .windowsInUse(let name):
            return tr("Cierra \(name) (y los demás programas de su mismo instalador) y vuelve a intentarlo: hay que cambiar ajustes que comparten.",
                      "Close \(name) (and the other programs from its installer) and try again: settings they share have to change.")
        case .installerStopped(let message, let log):
            return tr("El instalador se detuvo: «\(message)». Registro: \(log.path)",
                      "The installer stopped: “\(message)”. Log: \(log.path)")
        case .dotNetFailed(let release):
            return tr("No se pudo instalar .NET Framework 4.8 (versión encontrada: \(release.map(String.init) ?? "ninguna")).",
                      "Could not install .NET Framework 4.8 (version found: \(release.map(String.init) ?? "none")).")
        case .sharedWindowsMissing:
            return tr("Esta app es de una versión anterior de Vitral y guarda sus archivos de otra forma. Desinstálala e instálala de nuevo para agregarle programas.",
                      "This app comes from an earlier Vitral and keeps its files another way. Uninstall it and install it again to add programs to it.")
        case .prerequisiteLoop(let package, let log):
            let name = BurnLog.friendlyName(package)
            return tr("El instalador repetía sin parar la instalación de \(name): termina sin instalar nada en Wine y el instalador vuelve a pedirlo. Lo detuve. Este programa todavía no se puede instalar con Vitral. Registro: \(log.path)",
                      "The installer kept installing \(name) over and over: under Wine it ends without installing anything, and the installer asks for it again. I stopped it. This program cannot be installed with Vitral yet. Log: \(log.path)")
        }
    }
}

public struct InstallOptions: Sendable {
    /// Folder where the app goes (`~/Applications` by default).
    public var destination: URL
    /// Name for the app; by default the program's own name.
    public var name: String?
    /// Vitral's launcher binary, copied into the app.
    public var launcher: URL
    /// Move an existing app with the same name to the Trash instead of picking a new name.
    public var replace: Bool
    /// Passed to the installer, such as Inno Setup's `/VERYSILENT` (unattended installations).
    public var installerArguments: [String]

    public init(destination: URL = InstallOptions.defaultDestination, name: String? = nil, launcher: URL, replace: Bool = false,
                installerArguments: [String] = []) {
        self.destination = destination
        self.name = name
        self.launcher = launcher
        self.replace = replace
        self.installerArguments = installerArguments
    }

    /// `~/Applications`, or `VITRAL_APPLICATIONS` if set (for tests).
    public static var defaultDestination: URL {
        if let custom = ProcessInfo.processInfo.environment["VITRAL_APPLICATIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    /// `vitral-launcher` next to the running executable (the `vitral` tool or the app), or
    /// `VITRAL_LAUNCHER` if set.
    public static func findLauncher() -> URL? {
        if let custom = ProcessInfo.processInfo.environment["VITRAL_LAUNCHER"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let url = Bundle.main.url(forAuxiliaryExecutable: "vitral-launcher") { return url }
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("vitral-launcher")
        return FileManager.default.isExecutableFile(atPath: beside.path) ? beside : nil
    }
}

public struct InstallResult: Sendable {
    public let app: URL
    public let manifest: WrapperManifest
    public let report: ProgramReport
    public let log: URL
    /// Windows functions the program uses that the engine lacks (see `EngineCheck`).
    public let missingImports: [MissingImport]
    /// Other programs the installer made shortcuts for (a suite, or a program with its editor):
    /// each can become its own app on the same Windows (`ProgramInstaller.addProgram`).
    public var otherPrograms: [ProgramChoice] = []
}

/// Installs a Windows program and turns it into a Mac app.
public struct ProgramInstaller: Sendable {
    public let home: VitralHome
    public let engine: WineEngine

    public init(home: VitralHome = .default, engine: WineEngine = EngineCatalog.default) {
        self.home = home
        self.engine = engine
    }

    public var staging: URL { home.url.appendingPathComponent("Staging") }

    public static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vitral")
    }

    /// The newest installation log written since `date` (a ZIP's log is named after the
    /// installer inside it), for a report when an installation stops.
    public static func latestInstallLog(since date: Date, in folder: URL = logs) -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Instalación - ") && $0.pathExtension == "log" }
            .compactMap { url in (try? url.resourceValues(forKeys: keys).contentModificationDate).map { (url, $0) } }
            .filter { $0.1 >= date }
            .max { $0.1 < $1.1 }?.0
    }

    /// Why Vitral cannot install this file, or `nil` if it can.
    public static func refusal(_ report: InstallerReport) -> String? {
        if let info = report.executable {
            switch info.format {
            case .dos: return tr("Es un programa de MS-DOS: Wine no lo abre.", "It is an MS-DOS program: Wine does not open it.")
            case .windows16: return tr("Es un programa de Windows de 16 bits: Wine en Mac no los abre.",
                                       "It is a 16-bit Windows program: Wine on Mac does not open them.")
            case .pe32, .pe32Plus:
                if info.isDLL { return tr("Es una biblioteca (DLL), no un programa.", "It is a library (DLL), not a program.") }
            }
        }
        if report.kind == .unknown {
            return tr("No parece un instalador ni un programa de Windows.", "It does not look like a Windows installer or program.")
        }
        return nil
    }

    /// Runs the whole installation. The installer's windows appear on screen; the person
    /// follows its steps, and this returns when it has finished.
    ///
    /// `windowShown` gets each installer process that opens a window. Wine windows open behind
    /// the active app, and only the active app may hand the front over (an app calls
    /// `NSApp.yieldActivation(to:)` and then `activate()`); a command-line tool cannot.
    public func install(_ file: URL, options: InstallOptions,
                        windowShown: @escaping @Sendable (pid_t) -> Void = { _ in },
                        progress: @escaping @Sendable (InstallStage) -> Void = { _ in }) async throws -> InstallResult {
        let fm = FileManager.default
        progress(.checking)
        var installer = file
        var report = try InstallerAnalyzer.analyze(fileAt: file)
        // A ZIP that only holds an installer (Paint.NET): unpack it and run that installer.
        var unpacked: URL?
        defer { if let unpacked { try? fm.removeItem(at: unpacked) } }
        if report.kind == .zip, let inner = try await Self.installerInside(zip: file, unpackingIn: staging) {
            (unpacked, installer, report) = (inner.folder, inner.file, inner.report)
        }
        // A CD or DVD image: mounted while installing, and in Windows' eyes a CD drive.
        var disc: DiscImage?
        defer { disc?.eject() }
        if report.kind == .discImage {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let mounted = try await DiscImage.mount(file, in: staging)
            disc = mounted
            guard let setup = mounted.setupProgram else { throw DiscImageError.noSetup(label: report.discLabel) }
            (installer, report) = (setup, try InstallerAnalyzer.analyze(fileAt: setup))
        }
        // What the person chose: the disc image, the ZIP or the installer itself.
        let source = disc == nil ? installer : file
        if let reason = Self.refusal(report) { throw InstallError.unsupported(reason) }
        guard MacSystem.hasRosetta else { throw InstallError.rosettaMissing }
        guard fm.isExecutableFile(atPath: options.launcher.path) else { throw InstallError.launcherMissing }

        // The engine, downloaded and verified if needed.
        let components = ComponentInstaller(home: home)
        let pending = engine.components.filter { !components.isInstalled($0) }
        if !pending.isEmpty {
            let total = Double(pending.reduce(0) { $0 + $1.bytes })
            var done = 0.0
            for piece in pending {
                let share = Double(piece.bytes) / max(total, 1), base = done
                try await components.install(piece) { progress(.downloadingEngine(base + $0 * share)) }
                done += share
            }
        }
        let installed = InstalledEngine(engine: engine, home: home)

        // Everything happens in a staging folder; the app is moved into place at the end, and its
        // Windows into Vitral's Prefixes folder.
        let work = staging.appendingPathComponent(UUID().uuidString + ".app")
        let wrapper = Wrapper(url: work)
        let prefix = staging.appendingPathComponent(UUID().uuidString + ".prefix")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.logs, withIntermediateDirectories: true)
        let log = Self.logs.appendingPathComponent("Instalación - \(Wrapper.safeName(source.deletingPathExtension().lastPathComponent)).log")
        fm.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let session = WineSession(engine: installed, prefix: prefix)
        do {
            progress(.preparingWindows)
            try await session.createPrefix()
            try Task.checkCancellation()
            let setup = Recipes.installerSettings(for: report)
            var discDrive: String?
            if let disc {
                let letter = try disc.attach(to: prefix)
                discDrive = letter
                logHandle.write(Data("[Vitral] Disc \(report.fileName) from \(file.lastPathComponent) as drive \(letter.uppercased()): (\(DiscImage.label(of: try Data(contentsOf: file, options: .alwaysMapped)) ?? "no label"))\n".utf8))
            }
            try await session.importRegistry(setup.registry + (discDrive.map { [DiscImage.driveType($0)] } ?? []))
            for recipe in setup.applied {
                logHandle.write(Data("[Vitral] \(Recipes.describe(recipe.id)) (\(recipe.because))\n".utf8))
            }
            let before = ProgramFinder.snapshot(driveC: session.driveC)
            let shortcutsBefore = ProgramShortcuts.snapshot(driveC: session.driveC)

            // Microsoft's .NET Framework, installed into this prefix when something needs it.
            var dotNetRecipe: AppliedRecipe?
            func installDotNet(because: String) async throws {
                logHandle.write(Data("[Vitral] Installing .NET Framework 4.8: \(because)\n".utf8))
                progress(.installingDotNet(0))
                try await DotNetFramework.install(in: session, home: home, log: logHandle) { progress(.installingDotNet($0)) }
                dotNetRecipe = DotNetFramework.recipe(because: because)
            }

            enum Outcome { case finished(closedProgram: Bool), loop(String), stopped(String) }
            /// Runs the installer once and waits for what it left running.
            func runOnce(ignoringLogs: Set<String>) async throws -> Outcome {
                progress(Self.needsInstaller(installer, report) ? .runningInstaller() : .copyingProgram)
                let watcher = Task { await Self.reportNewWindows(to: windowShown) }
                defer { watcher.cancel() }
                // What it is doing, from its processes: its own windows do not always say it.
                let watchSteps = Self.needsInstaller(installer, report), installerName = installer.lastPathComponent
                let activity = Task {
                    guard watchSteps else { return }
                    var last: String?
                    while !Task.isCancelled {
                        let step = InstallerActivity.current(prefix: session.prefix, installer: installerName)
                        if step != last, !Task.isCancelled {
                            last = step
                            progress(.runningInstaller(step))
                        }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                defer { activity.cancel() }
                // Some installers open the program and wait until it is closed (Inno Setup's
                // [Run] entries without "nowait"): watch for it while the installer runs too.
                let launch = Task { await Self.waitForLaunchedProgram(driveC: session.driveC, before: before) }
                let closedWhileRunning = Task {
                    guard await launch.value else { return false }
                    progress(.closingProgram)
                    await session.killServer()
                    return true
                }
                // WiX Burn bundles that install a prerequisite again and again (.NET Framework).
                let loop = Task { await BurnLog.waitForRepeat(driveC: session.driveC, ignoring: ignoringLogs) }
                let stoppedLoop = Task { () -> String? in
                    guard let package = await loop.value else { return nil }
                    logHandle.write(Data("[Vitral] Burn installed \(package) twice: stopping the installer.\n".utf8))
                    await session.killServer()
                    return package
                }
                defer { loop.cancel(); launch.cancel() }
                do {
                    try await runInstaller(installer, report: report, arguments: options.installerArguments, session: session, log: logHandle, logURL: log)
                } catch {
                    activity.cancel()
                    await activity.value
                    launch.cancel()
                    loop.cancel()
                    if let package = await stoppedLoop.value { return .loop(package) }
                    // Closing everything may end msiexec with an error; the installation was done.
                    if !(await closedWhileRunning.value) { throw error }
                }
                // The installer ended: no more steps to show.
                activity.cancel()
                await activity.value
                launch.cancel()
                loop.cancel()
                if let package = await stoppedLoop.value { return .loop(package) }
                if await closedWhileRunning.value { return .finished(closedProgram: true) }
                try Task.checkCancellation()
                // An Inno Setup installer whose own checks failed before it showed anything.
                if report.kind == .innoSetup, let message = InnoSetupLog.fatalError(driveC: session.driveC) {
                    logHandle.write(Data("[Vitral] Inno Setup stopped: \(message)\n".utf8))
                    return .stopped(message)
                }
                if Self.needsInstaller(installer, report) { progress(.finishingInstaller) }
                let closed = await waitForLeftovers(session, before: before, closing: { progress(.closingProgram) })
                try Task.checkCancellation()
                return .finished(closedProgram: closed)
            }

            // Cancelling closes every Windows process of the prefix: the installer and anything
            // it opened. The waits below then end, and the staging folder is removed.
            let closedProgram = try await withTaskCancellationHandler {
                // An installer that is itself a .NET Framework program needs it to open.
                if DotNetFramework.needed(by: report.executable?.dotNetRuntime) {
                    try await installDotNet(because: "the installer is a .NET Framework program")
                }
                var outcome = try await runOnce(ignoringLogs: [])
                if case .loop(let package) = outcome {
                    // Microsoft's own .NET installer ends without installing anything under Wine
                    // (it thinks Windows 10 has it): install it the way that works, then again.
                    guard BurnLog.isDotNetFramework(package), dotNetRecipe == nil else {
                        throw InstallError.prerequisiteLoop(package, log: log)
                    }
                    try await installDotNet(because: "the installer asks for \(BurnLog.friendlyName(package))")
                    outcome = try await runOnce(ignoringLogs: BurnLog.logs(driveC: session.driveC))
                    if case .loop(let again) = outcome { throw InstallError.prerequisiteLoop(again, log: log) }
                }
                if case .stopped(let message) = outcome {
                    // Installers check for .NET Framework before anything else, and some fail
                    // there when it is missing (Greenshot's: "Unknown custom message name lcid").
                    // A real Windows has it; give this one too, once.
                    guard dotNetRecipe == nil, !DotNetFramework.isInstalled(prefix: prefix) else {
                        throw InstallError.installerStopped(message, log: log)
                    }
                    try await installDotNet(because: "the installer stopped while checking what it needs (\(message))")
                    outcome = try await runOnce(ignoringLogs: BurnLog.logs(driveC: session.driveC))
                    if case .stopped(let again) = outcome { throw InstallError.installerStopped(again, log: log) }
                    if case .loop(let again) = outcome { throw InstallError.prerequisiteLoop(again, log: log) }
                }
                guard case .finished(let closed) = outcome else { return false }
                return closed
            } onCancel: {
                Task { await session.killServer() }
            }
            if closedProgram {
                logHandle.write(Data(tr("[Vitral] El instalador abrió el programa: lo cerré para terminar la app.\n",
                                        "[Vitral] The installer opened the program: closed it to finish the app.\n").utf8))
            }
            // The disc leaves the drive: the app does not keep it.
            if let discDrive {
                await session.waitForServer()
                DiscImage.detach(letter: discDrive, from: prefix)
            }

            progress(.findingProgram)
            let after = ProgramFinder.snapshot(driveC: session.driveC)
            guard var found = ProgramFinder.choose(newFolders: after.subtracting(before), driveC: session.driveC),
                  var main = found.report.mainExecutable else {
                throw InstallError.programNotFound(log: log)
            }
            // The installer's shortcuts list its programs: the one Vitral would pick if it is
            // among them, otherwise the first in that folder, otherwise the first.
            let choices = ProgramShortcuts.programs(
                shortcuts: ProgramShortcuts.snapshot(driveC: session.driveC).subtracting(shortcutsBefore), driveC: session.driveC)
            let picked = choices.first { $0.program.lowercased() == (found.folder + "/" + main).lowercased() }
                ?? choices.first { ($0.program.lowercased() + "/").hasPrefix(found.folder.lowercased() + "/") }
                ?? choices.first
            if let picked {
                logHandle.write(Data("[Vitral] Shortcuts: \(choices.map { "\($0.name) → \($0.program)" }.joined(separator: "; "))\n".utf8))
                if picked.program.lowercased() != (found.folder + "/" + main).lowercased(),
                   let report = try? ProgramAnalyzer.analyze(folderAt: session.driveC.appendingPathComponent(picked.folder),
                                                             preferring: picked.fileName),
                   report.mainExecutable?.lowercased() == picked.fileName.lowercased() {
                    found = (folder: picked.folder, report: report)
                    main = picked.fileName
                }
            }
            let others = choices.filter { $0 != picked }

            // A program built on .NET Framework 4 whose installer did not bring it.
            if dotNetRecipe == nil, found.report.technology(.dotNet) == nil,
               let runtime = found.report.technology(.dotNetFramework)?.version, DotNetFramework.needed(by: runtime),
               !DotNetFramework.isInstalled(prefix: prefix) {
                try await withTaskCancellationHandler {
                    try await installDotNet(because: "the program is built on .NET Framework (\(runtime))")
                } onCancel: {
                    Task { await session.killServer() }
                }
            }

            // Pages shown with Internet Explorer's control need Wine's HTML engine. Without it the
            // program still opens, with those pages blank; its launcher tries again then.
            var geckoRecipe: AppliedRecipe?
            if let browser = found.report.technology(.internetExplorer) {
                let architecture = WineGecko.architecture(of: found.report.executable)
                if !WineGecko.isInstalled(architecture, prefix: prefix) {
                    logHandle.write(Data("[Vitral] Installing Wine Gecko \(WineGecko.version) (\(architecture.rawValue)): \(browser.evidence) shows pages with Internet Explorer's control\n".utf8))
                    progress(.installingBrowser(0))
                    do {
                        try await WineGecko.install(architecture, in: session, home: home, log: logHandle) { progress(.installingBrowser($0)) }
                        geckoRecipe = WineGecko.recipe(because: "\(browser.evidence) uses Internet Explorer's control")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        logHandle.write(Data("[Vitral] Wine Gecko not installed: \(error)\n".utf8))
                    }
                    try Task.checkCancellation()
                }
            }

            progress(.applyingSettings)
            var (settings, applied) = Recipes.settings(for: found.report)
            // Programs the catalog knows by name get their fixes now, not after failing.
            let known = RepairPlanner.knownProgram(names: RepairPlanner.names(of: found.report.executable?.version,
                                                                               installer: source.lastPathComponent),
                                                   settings: settings)
            settings = known.settings
            applied += known.applied
            for recipe in known.applied {
                logHandle.write(Data("[Vitral] Known program: \(recipe.id) [\(recipe.because)]\n".utf8))
            }
            if let picked { settings.arguments = picked.arguments + settings.arguments }
            // The installer's settings stay in the prefix; the manifest lists them too.
            settings.registry = setup.registry + settings.registry
            applied = setup.applied + applied
            if let dotNetRecipe { applied.append(dotNetRecipe) }
            if let geckoRecipe { applied.append(geckoRecipe) }
            try await session.importRegistry(settings.registry)

            let program = found.folder + "/" + main
            let missing = EngineCheck.missingImports(program: session.driveC.appendingPathComponent(program),
                                                     engine: installed, prefix: prefix)
            for item in missing { logHandle.write(Data("[Vitral] \(item.logLine)\n".utf8)) }

            try Task.checkCancellation()
            progress(.buildingApp)
            let product = found.report.executable?.version
            // With several programs, the shortcuts' names tell them apart ("MetaTrader 5", "MetaEditor 5").
            let name = Wrapper.safeName(options.name ?? (others.isEmpty ? nil : picked?.name) ?? product?.productName ?? product?.fileDescription
                ?? found.folder.split(separator: "/").last.map(String.init) ?? installer.deletingPathExtension().lastPathComponent)
            let identifier = Wrapper.bundleIdentifier(for: name)
            let manifest = WrapperManifest(name: name, program: program, engine: engine.id, settings: settings,
                                           recipes: applied, product: product, installer: source.lastPathComponent,
                                           installerSHA256: try? ComponentInstaller.sha256(of: source), prefix: identifier)
            let exe = session.driveC.appendingPathComponent(program)
            let icns = (try? Data(contentsOf: exe, options: .alwaysMapped))
                .flatMap(PortableExecutable.icon).flatMap { AppIcon.icns(fromICO: $0) }
            try wrapper.write(manifest: manifest, icns: icns, launcher: options.launcher, bundleIdentifier: identifier)

            try fm.createDirectory(at: home.prefixes, withIntermediateDirectories: true)
            try fm.moveItem(at: prefix, to: home.prefixes.appendingPathComponent(identifier))
            let final: URL
            do {
                final = try place(work, named: name, in: options.destination, replace: options.replace)
            } catch {
                try? fm.removeItem(at: home.prefixes.appendingPathComponent(identifier))
                throw error
            }
            return InstallResult(app: final, manifest: manifest, report: found.report, log: log, missingImports: missing,
                                 otherPrograms: others)
        } catch {
            await session.killServer()
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: prefix)   // its links to the person's folders go, not the folders
            throw error
        }
    }

    /// Makes another app for a program of `app`'s Windows (one of `InstallResult.otherPrograms`,
    /// or of `ProgramShortcuts.available`). Both apps share that Windows: what one program
    /// saves there, the other sees, and uninstalling one keeps it for the other.
    public func addProgram(_ choice: ProgramChoice, sharingWindowsOf app: URL, launcher: URL) async throws -> URL {
        let fm = FileManager.default
        let source = Wrapper(url: app)
        let manifest = try source.readManifest()
        guard let shared = manifest.prefix else { throw InstallError.sharedWindowsMissing }
        let engine = EngineCatalog.engine(id: manifest.engine) ?? EngineCatalog.default
        let installed = InstalledEngine(engine: engine, home: home)
        let session = WineSession(engine: installed, prefix: source.prefix(in: home))
        let report = try ProgramAnalyzer.analyze(folderAt: session.driveC.appendingPathComponent(choice.folder),
                                                 preferring: choice.fileName)
        guard report.mainExecutable?.lowercased() == choice.fileName.lowercased() else {
            throw InstallError.programNotFound(log: ProgramInstaller.logs)
        }
        var (settings, applied) = Recipes.settings(for: report)
        let known = RepairPlanner.knownProgram(names: RepairPlanner.names(of: report.executable?.version, installer: manifest.installer),
                                               settings: settings)
        settings = known.settings
        applied += known.applied
        settings.arguments = choice.arguments + settings.arguments
        if !settings.registry.isEmpty {
            // Registry changes are saved when the Windows stops; the other program keeps it running.
            guard !session.serverIsRunning else { throw InstallError.windowsInUse(manifest.name) }
            try await session.importRegistry(settings.registry)
        }

        let name = Wrapper.safeName(choice.name)
        let identifier = Wrapper.bundleIdentifier(for: name)
        let newManifest = WrapperManifest(name: name, program: choice.program, engine: manifest.engine, settings: settings,
                                          recipes: applied, product: report.executable?.version,
                                          installer: manifest.installer, installerSHA256: manifest.installerSHA256, prefix: shared)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let work = staging.appendingPathComponent(UUID().uuidString + ".app")
        do {
            let exe = session.driveC.appendingPathComponent(choice.program)
            let icns = (try? Data(contentsOf: exe, options: .alwaysMapped))
                .flatMap(PortableExecutable.icon).flatMap { AppIcon.icns(fromICO: $0) }
            try Wrapper(url: work).write(manifest: newManifest, icns: icns, launcher: launcher, bundleIdentifier: identifier)
            return try place(work, named: name, in: app.deletingLastPathComponent(), replace: false)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Calls `shown` once for each Windows process that opens a window from now on.
    static func reportNewWindows(to shown: @Sendable (pid_t) -> Void) async {
        // Programs that were already open are not the installer's.
        let before = Set(WineWindows.owners().map(\.pid))
        // A process is reported each time it goes from no window to a window: installers that
        // close their window and open another (WiX Burn after each prerequisite) would
        // otherwise open it behind Vitral.
        var showing = Set<pid_t>()
        while !Task.isCancelled {
            let now = Set(WineWindows.owners().filter { !before.contains($0.pid) && WineWindows.looksLikeWindows($0.name) }.map(\.pid))
            for pid in now.subtracting(showing) { shown(pid) }
            showing = now
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Waits until what the installer left running has ended. Many installers end with
    /// "Launch <program>" checked: that copy runs without Vitral's settings and would keep the
    /// installation waiting until the person closed it, so it is closed as soon as one of its
    /// windows appears. Returns whether it closed the program.
    private func waitForLeftovers(_ session: WineSession, before: Set<String>,
                                  closing: @escaping @Sendable () -> Void) async -> Bool {
        // Background services alone (the .NET optimizer, Edge's updater) do not keep the
        // installation waiting: a few quiet seconds and the prefix is closed.
        var quiet = 0
        while !Task.isCancelled, session.serverIsRunning {
            let processes = WineProcesses.list(prefix: session.prefix)
            if Self.installedProgramIsRunning(processes, driveC: session.driveC, before: before) {
                closing()
                await session.killServer()
                return true
            }
            quiet = processes.allSatisfy { WineProcesses.isBackground($0.name) } ? quiet + 1 : 0
            if quiet >= 3 {
                await session.killServer()
                return false
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await session.waitForServer()
        return false
    }

    /// Whether a program the installer added runs in the prefix, with a window or without one
    /// (a menu bar program such as Greenshot).
    static func installedProgramIsRunning(_ processes: [WineProcesses.Entry], driveC: URL, before: Set<String>) -> Bool {
        let running = Set(processes.map { $0.name.lowercased() }.filter { $0.hasSuffix(".exe") && !WineProcesses.isBackground($0) })
        guard !running.isEmpty else { return false }
        let added = ProgramFinder.snapshot(driveC: driveC).subtracting(before)
        return !running.isDisjoint(with: ProgramFinder.executableNames(inFolders: added, driveC: driveC))
    }

    /// Returns true as soon as the installed program's main executable (the one Vitral would
    /// make the app open) has a window; false if cancelled. Other new programs with a window,
    /// such as a runtime installer the setup runs from the program's folder (Shape It! runs
    /// `vc_redist.x86.exe` from there), do not count.
    static func waitForLaunchedProgram(driveC: URL, before: Set<String>) async -> Bool {
        var known: (added: Set<String>, main: String?)?
        while !Task.isCancelled {
            let open = Set(WineWindows.owners().map { $0.name.lowercased() }.filter { $0.hasSuffix(".exe") })
            if !open.isEmpty {
                let added = ProgramFinder.snapshot(driveC: driveC).subtracting(before)
                // Cheap check first; the analysis only runs when a new program has a window,
                // and again only if the new folders changed.
                if !open.isDisjoint(with: ProgramFinder.executableNames(inFolders: added, driveC: driveC)) {
                    if known?.added != added {
                        let main = ProgramFinder.choose(newFolders: added, driveC: driveC)?.report.mainExecutable
                        known = (added, main.map { ($0 as NSString).lastPathComponent.lowercased() })
                    }
                    if let main = known?.main, open.contains(main) { return true }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Whether a program the installer added has a window open.
    static func installedProgramIsOpen(driveC: URL, before: Set<String>) -> Bool {
        let open = Set(WineWindows.owners().map { $0.name.lowercased() }.filter { $0.hasSuffix(".exe") })
        guard !open.isEmpty else { return false }
        let added = ProgramFinder.snapshot(driveC: driveC).subtracting(before)
        return !open.isDisjoint(with: ProgramFinder.executableNames(inFolders: added, driveC: driveC))
    }

    /// Opens the installer the right way for its kind, or copies a portable program in.
    private func runInstaller(_ installer: URL, report: InstallerReport, arguments: [String] = [], session: WineSession,
                              log: FileHandle, logURL: URL) async throws {
        let folder = installer.deletingLastPathComponent()
        let programFiles = session.driveC.appendingPathComponent("Program Files")
        let base = Wrapper.safeName(installer.deletingPathExtension().lastPathComponent)
        switch report.kind {
        case .msi:
            let status = try await session.run(["msiexec", "/i", installer.path] + arguments, directory: folder, output: log)
            if status != 0 { throw InstallError.installerDidNotStart(status, log: logURL) }
        case .zip:
            // A portable program in a ZIP: unpack it into Program Files.
            let target = programFiles.appendingPathComponent(base)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", installer.path, target.path]
            unzip.standardOutput = log
            unzip.standardError = log
            let status = try await WineSession.wait(for: unzip)
            if status != 0 { throw InstallError.installerDidNotStart(status, log: logURL) }
        case .executable where !Self.looksLikeSetup(installer.lastPathComponent):
            // A program that is not an installer: copy it in as it is.
            let target = programFiles.appendingPathComponent(base)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: installer, to: target.appendingPathComponent(installer.lastPathComponent))
        case .innoSetup:
            // Its own log says why it stopped, when it does (`InnoSetupLog`).
            try? FileManager.default.removeItem(at: InnoSetupLog.file(driveC: session.driveC))
            _ = try await session.run([installer.path, "/LOG=" + InnoSetupLog.windowsPath] + arguments, directory: folder, output: log)
        default:
            // Run from its own folder, so it finds the files next to it (Setup-1a.bin…).
            let status = try await session.run([installer.path] + arguments, directory: folder, output: log)
            // Installers return non-zero when cancelled; the program search decides what happened.
            _ = status
        }
    }

    /// The installer a ZIP holds, unpacked into a new folder in `staging`, when the ZIP holds just
    /// that: one `.exe` or `.msi` that is an installer. Nil for anything else (a portable program
    /// is unpacked into Program Files later).
    static func installerInside(zip: URL, unpackingIn staging: URL) async throws
        -> (folder: URL, file: URL, report: InstallerReport)? {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        try list.run()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") && !($0 as NSString).lastPathComponent.hasPrefix(".") }
        list.waitUntilExit()
        guard list.terminationStatus == 0, names.count == 1, let name = names.first,
              !name.contains(".."), ["exe", "msi"].contains((name as NSString).pathExtension.lowercased()) else { return nil }

        let folder = staging.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, folder.path]
        let status = try await WineSession.wait(for: unzip)
        let file = folder.appendingPathComponent(name)
        guard status == 0, let report = try? InstallerAnalyzer.analyze(fileAt: file),
              needsInstaller(file, report), report.kind != .zip else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return (folder, file, report)
    }

    /// Whether the file is an installer to run (or a ZIP or portable program to copy in).
    public static func needsInstaller(_ file: URL, _ report: InstallerReport) -> Bool {
        switch report.kind {
        case .zip: return false
        case .executable: return looksLikeSetup(file.lastPathComponent)
        case .discImage: return true
        default: return true
        }
    }

    public static func looksLikeSetup(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        return ["setup", "install", "instal"].contains { name.contains($0) }
    }

    /// Moves the finished app into the destination, picking "Name 2.app" if the name is taken.
    private func place(_ work: URL, named name: String, in destination: URL, replace: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var target = destination.appendingPathComponent(name + ".app")
        if fm.fileExists(atPath: target.path) {
            if replace {
                // The replaced app's Windows goes to the Trash with it.
                let old = Wrapper(url: target)
                let oldManifest = try? old.readManifest()
                let shared = Uninstaller.otherManifests(besides: target).contains { $0.prefix != nil && $0.prefix == oldManifest?.prefix }
                let oldPrefix = oldManifest?.prefix != nil && !shared ? old.prefix(in: home) : nil
                try fm.trashItem(at: target, resultingItemURL: nil)
                if let oldPrefix, fm.fileExists(atPath: oldPrefix.path) { try? fm.trashItem(at: oldPrefix, resultingItemURL: nil) }
            } else {
                var number = 2
                while fm.fileExists(atPath: target.path) {
                    target = destination.appendingPathComponent("\(name) \(number).app")
                    number += 1
                }
            }
        }
        try fm.moveItem(at: work, to: target)
        return target
    }
}
