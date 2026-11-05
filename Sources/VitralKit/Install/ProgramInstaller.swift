import Foundation

/// Steps of an installation, for progress messages.
public enum InstallStage: Sendable, Equatable {
    case checking
    case downloadingEngine(Double)
    case preparingWindows
    /// The installer is open: the person follows its steps.
    case runningInstaller
    /// The installer ended; something it started is still running (the program, a helper).
    case finishingInstaller
    /// The installer opened the program ("Launch …" checked): Vitral closes that copy.
    case closingProgram
    /// A ZIP or a program that is not an installer: copied in, nothing to click.
    case copyingProgram
    case findingProgram
    case applyingSettings
    case buildingApp
}

public enum InstallError: Error, CustomStringConvertible {
    case unsupported(String)
    case rosettaMissing
    case launcherMissing
    case programNotFound(log: URL)
    case installerDidNotStart(Int32, log: URL)

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

    public init(destination: URL = InstallOptions.defaultDestination, name: String? = nil, launcher: URL, replace: Bool = false) {
        self.destination = destination
        self.name = name
        self.launcher = launcher
        self.replace = replace
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
    public func install(_ installer: URL, options: InstallOptions,
                        windowShown: @escaping @Sendable (pid_t) -> Void = { _ in },
                        progress: @escaping @Sendable (InstallStage) -> Void = { _ in }) async throws -> InstallResult {
        let fm = FileManager.default
        progress(.checking)
        let report = try InstallerAnalyzer.analyze(fileAt: installer)
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

        // Everything happens in a staging folder; the app is moved into place at the end.
        let work = staging.appendingPathComponent(UUID().uuidString + ".app")
        let wrapper = Wrapper(url: work)
        try fm.createDirectory(at: wrapper.contents.appendingPathComponent("SharedSupport"), withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.logs, withIntermediateDirectories: true)
        let log = Self.logs.appendingPathComponent("Instalación - \(Wrapper.safeName(installer.deletingPathExtension().lastPathComponent)).log")
        fm.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let session = WineSession(engine: installed, prefix: wrapper.prefix)
        do {
            progress(.preparingWindows)
            try await session.createPrefix()
            try Task.checkCancellation()
            let setup = Recipes.installerSettings(for: report)
            try await session.importRegistry(setup.registry)
            for recipe in setup.applied {
                logHandle.write(Data("[Vitral] \(Recipes.describe(recipe.id)) (\(recipe.because))\n".utf8))
            }
            let before = ProgramFinder.snapshot(driveC: session.driveC)

            progress(Self.needsInstaller(installer, report) ? .runningInstaller : .copyingProgram)
            let watcher = Task { await Self.reportNewWindows(to: windowShown) }
            // Cancelling closes every Windows process of the prefix: the installer and anything
            // it opened. The waits below then end, and the staging folder is removed.
            let closedProgram = try await withTaskCancellationHandler {
                do {
                    try await runInstaller(installer, report: report, session: session, log: logHandle, logURL: log)
                } catch {
                    watcher.cancel()
                    throw error
                }
                watcher.cancel()
                try Task.checkCancellation()
                if Self.needsInstaller(installer, report) { progress(.finishingInstaller) }
                let closed = await waitForLeftovers(session, before: before, closing: { progress(.closingProgram) })
                try Task.checkCancellation()
                return closed
            } onCancel: {
                Task { await session.killServer() }
            }
            if closedProgram {
                logHandle.write(Data(tr("[Vitral] El instalador abrió el programa: lo cerré para terminar la app.\n",
                                        "[Vitral] The installer opened the program: closed it to finish the app.\n").utf8))
            }

            progress(.findingProgram)
            let after = ProgramFinder.snapshot(driveC: session.driveC)
            guard let found = ProgramFinder.choose(newFolders: after.subtracting(before), driveC: session.driveC),
                  let main = found.report.mainExecutable else {
                throw InstallError.programNotFound(log: log)
            }

            progress(.applyingSettings)
            var (settings, applied) = Recipes.settings(for: found.report)
            // The installer's settings stay in the prefix; the manifest lists them too.
            settings.registry = setup.registry + settings.registry
            applied = setup.applied + applied
            try await session.importRegistry(settings.registry)

            let program = found.folder + "/" + main
            let missing = EngineCheck.missingImports(program: session.driveC.appendingPathComponent(program),
                                                     engine: installed, prefix: wrapper.prefix)
            for item in missing { logHandle.write(Data("[Vitral] \(item.logLine)\n".utf8)) }

            try Task.checkCancellation()
            progress(.buildingApp)
            let product = found.report.executable?.version
            let name = Wrapper.safeName(options.name ?? product?.productName ?? product?.fileDescription
                ?? found.folder.split(separator: "/").last.map(String.init) ?? installer.deletingPathExtension().lastPathComponent)
            let manifest = WrapperManifest(name: name, program: program, engine: engine.id, settings: settings,
                                           recipes: applied, product: product, installer: installer.lastPathComponent)
            let exe = session.driveC.appendingPathComponent(program)
            let icns = (try? Data(contentsOf: exe, options: .alwaysMapped))
                .flatMap(PortableExecutable.icon).flatMap { AppIcon.icns(fromICO: $0) }
            try wrapper.write(manifest: manifest, icns: icns, launcher: options.launcher,
                              bundleIdentifier: Wrapper.bundleIdentifier(for: name))

            let final = try place(work, named: name, in: options.destination, replace: options.replace)
            return InstallResult(app: final, manifest: manifest, report: found.report, log: log, missingImports: missing)
        } catch {
            await session.killServer()
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Calls `shown` once for each Windows process that opens a window from now on.
    static func reportNewWindows(to shown: @Sendable (pid_t) -> Void) async {
        var seen = Set(WineWindows.owners().map(\.pid))
        while !Task.isCancelled {
            for owner in WineWindows.owners() where !seen.contains(owner.pid) && WineWindows.looksLikeWindows(owner.name) {
                seen.insert(owner.pid)
                shown(owner.pid)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Waits until what the installer left running has ended. Many installers end with
    /// "Launch <program>" checked: that copy runs without Vitral's settings and would keep the
    /// installation waiting until the person closed it, so it is closed as soon as one of its
    /// windows appears. Returns whether it closed the program.
    private func waitForLeftovers(_ session: WineSession, before: Set<String>,
                                  closing: @escaping @Sendable () -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await session.waitForServer()
                return false
            }
            group.addTask {
                while !Task.isCancelled {
                    if Self.installedProgramIsOpen(driveC: session.driveC, before: before) { return true }
                    try? await Task.sleep(for: .seconds(1))
                }
                return false
            }
            let closed = await group.next() ?? false
            if closed {
                closing()
                await session.killServer()
            }
            group.cancelAll()
            return closed
        }
    }

    /// Whether a program the installer added has a window open.
    static func installedProgramIsOpen(driveC: URL, before: Set<String>) -> Bool {
        let open = Set(WineWindows.owners().map { $0.name.lowercased() }.filter { $0.hasSuffix(".exe") })
        guard !open.isEmpty else { return false }
        let added = ProgramFinder.snapshot(driveC: driveC).subtracting(before)
        return !open.isDisjoint(with: ProgramFinder.executableNames(inFolders: added, driveC: driveC))
    }

    /// Opens the installer the right way for its kind, or copies a portable program in.
    private func runInstaller(_ installer: URL, report: InstallerReport, session: WineSession,
                              log: FileHandle, logURL: URL) async throws {
        let folder = installer.deletingLastPathComponent()
        let programFiles = session.driveC.appendingPathComponent("Program Files")
        let base = Wrapper.safeName(installer.deletingPathExtension().lastPathComponent)
        switch report.kind {
        case .msi:
            let status = try await session.run(["msiexec", "/i", installer.path], directory: folder, output: log)
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
        default:
            // Run from its own folder, so it finds the files next to it (Setup-1a.bin…).
            let status = try await session.run([installer.path], directory: folder, output: log)
            // Installers return non-zero when cancelled; the program search decides what happened.
            _ = status
        }
    }

    /// Whether the file is an installer to run (or a ZIP or portable program to copy in).
    public static func needsInstaller(_ file: URL, _ report: InstallerReport) -> Bool {
        switch report.kind {
        case .zip: return false
        case .executable: return looksLikeSetup(file.lastPathComponent)
        default: return true
        }
    }

    static func looksLikeSetup(_ fileName: String) -> Bool {
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
                try fm.trashItem(at: target, resultingItemURL: nil)
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
