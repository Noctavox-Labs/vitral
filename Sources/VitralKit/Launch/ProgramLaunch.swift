import Foundation

public enum LaunchProblem: Error, CustomStringConvertible {
    case rosettaMissing
    case engineMissing(WineEngine)
    case programMissing(String)

    public var description: String {
        switch self {
        case .rosettaMissing:
            return tr("Para abrir programas de Windows, esta Mac necesita Rosetta.",
                      "To open Windows programs, this Mac needs Rosetta.")
        case .engineMissing(let engine):
            return tr("Falta el motor de Windows (\(engine.name)). Ábrelo en Vitral para descargarlo.",
                      "The Windows engine (\(engine.name)) is missing. Open Vitral to download it.")
        case .programMissing(let path):
            return tr("No encuentro el programa dentro de la app: \(path)", "The program is missing inside the app: \(path)")
        }
    }
}

/// Everything needed to open the program of one wrapper.
public struct ProgramLaunch: Sendable {
    public let wrapper: Wrapper
    public let manifest: WrapperManifest
    public let session: WineSession
    public let program: URL

    /// Checks Rosetta, the engine and the program, and prepares the Wine session.
    public init(wrapper: Wrapper, home: VitralHome = .default) throws {
        try self.init(wrapper: wrapper, manifest: try wrapper.readManifest(), home: home)
    }

    /// The same, with other settings than the app's (a fix being tried).
    public init(wrapper: Wrapper, manifest: WrapperManifest, home: VitralHome = .default) throws {
        guard MacSystem.hasRosetta else { throw LaunchProblem.rosettaMissing }
        let engine = EngineCatalog.engine(id: manifest.engine) ?? EngineCatalog.default
        let components = ComponentInstaller(home: home)
        guard engine.components.allSatisfy(components.isInstalled) else { throw LaunchProblem.engineMissing(engine) }
        let prefix = wrapper.prefix(in: home)
        let program = try wrapper.programURL(manifest, prefix: prefix)
        guard FileManager.default.fileExists(atPath: program.path) else { throw LaunchProblem.programMissing(manifest.program) }

        self.wrapper = wrapper
        self.manifest = manifest
        self.program = program
        self.session = WineSession(engine: InstalledEngine(engine: engine, home: home), prefix: prefix,
                                   extraEnvironment: manifest.settings.environment)
    }

    /// Deletes what the recipes say must go before opening (stale locks…).
    @discardableResult
    public func clean() -> Int {
        PrefixFiles.clean(manifest.settings.cleanup, in: session.prefix)
    }

    /// The `wine` process for the program, started from the program's folder. It lives as long
    /// as the program does (the program itself runs in another process).
    public func makeProcess(log: FileHandle) -> Process {
        session.process([program.lastPathComponent] + manifest.settings.arguments,
                        directory: program.deletingLastPathComponent(), output: log)
    }

    /// Whether the program's process runs in this app's Windows, with or without a window.
    public func programIsRunning() -> Bool {
        let exe = program.lastPathComponent.lowercased()
        return WineProcesses.list(prefix: session.prefix).contains { $0.name.lowercased() == exe }
    }

    /// Windows on screen that belong to the program (its process is named after the `.exe`).
    public func programWindowOwners() -> [pid_t] {
        WineWindows.owners().filter { isProgram($0) }.map(\.pid)
    }

    /// The program's windows on screen, of every layer: message boxes that stay on top too.
    public func programWindows() -> [WineWindows.Window] {
        WineWindows.onScreen().filter { isProgram($0.owner) }
    }

    private func isProgram(_ owner: WineWindows.Owner) -> Bool {
        let name = owner.name.lowercased()
        return name == program.lastPathComponent.lowercased() || name == program.deletingPathExtension().lastPathComponent.lowercased()
    }
}

/// Decides what happened when the program ended.
public enum StartupWatch {
    /// Seconds after which an exit is the person closing the program, not a failed start.
    public static let startupWindow: TimeInterval = 40
    public static let maxAttempts = 3
    /// Seconds after which a program that runs without a window counts as open (menu bar programs).
    public static let menuBarProgramDelay: TimeInterval = 15

    /// Lines in Wine's log that mean the program crashed.
    static let crashSignatures = [
        "Unhandled page fault",
        "Unhandled exception",
        "Unhandled stack overflow",
        "Unhandled illegal instruction",
    ]

    public static func looksLikeCrash(log: String) -> Bool {
        crashSignatures.contains { log.contains($0) }
    }

    /// Whether to open the program again: it crashed while starting, before showing a window.
    /// (One start in four of Shape It! with CrossOver 24 crashes like this; the next one works.)
    /// Not after an error box: the same box would show again.
    public static func shouldRetry(ranFor seconds: TimeInterval, sawWindow: Bool, log: String, attempt: Int,
                                   errorBox: Bool = false) -> Bool {
        attempt < maxAttempts && !sawWindow && !errorBox && seconds < startupWindow && looksLikeCrash(log: log)
    }

    /// Whether the program failed to open: no window, and it ended early after crashing or with an
    /// error (Electron ends with status 3 when Chromium stops on purpose, and then Wine prints no
    /// "Unhandled" line); or it showed only error boxes and closed, however long one stayed open
    /// (Encarta 2009's "Application cannot start" ends with status 0).
    public static func failedToStart(ranFor seconds: TimeInterval, sawWindow: Bool, status: Int32, log: String,
                                     errorBox: Bool = false) -> Bool {
        !sawWindow && (errorBox || seconds < startupWindow && (status != 0 || looksLikeCrash(log: log)))
    }
}
