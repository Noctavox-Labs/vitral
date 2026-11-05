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
        let manifest = try wrapper.readManifest()
        guard MacSystem.hasRosetta else { throw LaunchProblem.rosettaMissing }
        let engine = EngineCatalog.engine(id: manifest.engine) ?? EngineCatalog.default
        let components = ComponentInstaller(home: home)
        guard engine.components.allSatisfy(components.isInstalled) else { throw LaunchProblem.engineMissing(engine) }
        let program = try wrapper.programURL(manifest)
        guard FileManager.default.fileExists(atPath: program.path) else { throw LaunchProblem.programMissing(manifest.program) }

        self.wrapper = wrapper
        self.manifest = manifest
        self.program = program
        self.session = WineSession(engine: InstalledEngine(engine: engine, home: home), prefix: wrapper.prefix,
                                   extraEnvironment: manifest.settings.environment)
    }

    /// Deletes what the recipes say must go before opening (stale locks…).
    @discardableResult
    public func clean() -> Int {
        PrefixFiles.clean(manifest.settings.cleanup, in: wrapper.prefix)
    }

    /// The `wine` process for the program, started from the program's folder. It lives as long
    /// as the program does (the program itself runs in another process).
    public func makeProcess(log: FileHandle) -> Process {
        session.process([program.lastPathComponent] + manifest.settings.arguments,
                        directory: program.deletingLastPathComponent(), output: log)
    }

    /// Windows on screen that belong to the program (its process is named after the `.exe`).
    public func programWindowOwners() -> [pid_t] {
        let exe = program.lastPathComponent.lowercased()
        let stem = program.deletingPathExtension().lastPathComponent.lowercased()
        return WineWindows.owners().filter { [exe, stem].contains($0.name.lowercased()) }.map(\.pid)
    }
}

/// Decides what happened when the program ended.
public enum StartupWatch {
    /// Seconds after which an exit is the person closing the program, not a failed start.
    public static let startupWindow: TimeInterval = 40
    public static let maxAttempts = 3

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
    public static func shouldRetry(ranFor seconds: TimeInterval, sawWindow: Bool, log: String, attempt: Int) -> Bool {
        attempt < maxAttempts && !sawWindow && seconds < startupWindow && looksLikeCrash(log: log)
    }

    /// Whether the program failed to open: no window, it ended early, and it crashed or ended
    /// with an error. (Electron ends with status 3 when Chromium stops on purpose, and then
    /// Wine prints no "Unhandled" line.)
    public static func failedToStart(ranFor seconds: TimeInterval, sawWindow: Bool, status: Int32, log: String) -> Bool {
        !sawWindow && seconds < startupWindow && (status != 0 || looksLikeCrash(log: log))
    }
}
