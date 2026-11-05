import AppKit
import Foundation
import Observation
import VitralKit

/// State of the whole app. Lives on the main actor; slow work runs in tasks.
@MainActor
@Observable
final class AppModel {
    enum TaskState: Equatable {
        case idle
        case working(progress: Double?, message: String)
        case failed(String)
    }

    enum InstallState: Equatable {
        case idle
        case working(InstallStage)
        /// The app, and a warning if the engine lacks something the program uses.
        case done(URL, warning: String?)
        case failed(String)
    }

    /// An app made by Vitral, found in ~/Applications.
    struct LibraryApp: Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let icon: NSImage
        let manifest: WrapperManifest
    }

    /// A Windows installer or program the person dropped, already analyzed.
    struct DroppedFile: Identifiable {
        let id = UUID()
        let url: URL
        let report: InstallerReport
        let icon: NSImage?
    }

    private(set) var mac = MacInfo.current()
    private(set) var requirements: [Requirement] = []
    var engineTask: TaskState = .idle
    var rosettaTask: TaskState = .idle
    var showSetup = false
    var dropped: DroppedFile?
    var dropError: String?
    var installState: InstallState = .idle
    private(set) var library: [LibraryApp] = []

    let engine = EngineCatalog.default
    private let installer = ComponentInstaller()

    init() {
        refresh()
        refreshLibrary()
        showSetup = needsSetup
    }

    var engineInstalled: Bool { engine.components.allSatisfy(installer.isInstalled) }

    /// Something still has to be installed or fixed before programs can run.
    var needsSetup: Bool { requirements.contains { $0.status == .fixable || $0.status == .blocking } }

    var engineDownloadBytes: Int64 {
        engine.components.filter { !installer.isInstalled($0) }.reduce(0) { $0 + $1.bytes }
    }

    func refresh() {
        mac = MacInfo.current()
        requirements = SystemCheck.requirements(mac: mac, engineInstalled: engineInstalled)
    }

    // MARK: Engine

    func installEngine() async {
        let pending = engine.components.filter { !installer.isInstalled($0) }
        let total = Double(pending.reduce(0) { $0 + $1.bytes })
        var done = 0.0
        engineTask = .working(progress: 0, message: String(localized: "Preparando la descarga…"))
        do {
            for piece in pending {
                let share = Double(piece.bytes) / max(total, 1)
                let base = done
                try await installer.install(piece) { fraction in
                    Task { @MainActor in
                        self.engineTask = .working(progress: base + fraction * share,
                                                   message: String(localized: "Descargando \(piece.name)"))
                    }
                }
                done += share
            }
            engineTask = .idle
        } catch {
            engineTask = .failed(String(describing: error))
        }
        refresh()
    }

    // MARK: Rosetta

    /// Installs Rosetta with the system's own administrator prompt, without the Terminal.
    func installRosetta() async {
        rosettaTask = .working(progress: nil, message: String(localized: "Instalando Rosetta…"))
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let status = await Self.run("/usr/bin/osascript", ["-e", script])
        refresh()
        if mac.hasRosetta {
            rosettaTask = .idle
        } else if status == 1 {
            // osascript returns 1 when the person cancels the password prompt.
            rosettaTask = .idle
        } else {
            rosettaTask = .failed(String(localized: "No se pudo instalar Rosetta. Revisa tu conexión a internet e inténtalo otra vez."))
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }

    // MARK: Dropped installers

    static let acceptedExtensions: Set<String> = ["exe", "msi", "zip"]

    func open(_ url: URL) {
        dropError = nil
        guard Self.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            dropError = String(localized: "Eso no parece un instalador de Windows. Vitral abre archivos .exe, .msi y .zip.")
            return
        }
        do {
            let report = try InstallerAnalyzer.analyze(fileAt: url)
            let icon = (try? Data(contentsOf: url, options: .alwaysMapped))
                .flatMap(PortableExecutable.icon)
                .flatMap(NSImage.init(data:))
            // Only one sheet at a time: the analysis replaces the setup assistant.
            showSetup = false
            if case .working = installState {} else { installState = .idle }
            dropped = DroppedFile(url: url, report: report, icon: icon)
        } catch {
            dropError = String(localized: "No pude leer ese archivo.")
        }
    }

    // MARK: Installing

    var isInstalling: Bool {
        if case .working = installState { return true }
        return false
    }

    /// Installs the dropped program and turns it into an app in ~/Applications.
    func install(_ file: DroppedFile) async {
        guard let launcher = InstallOptions.findLauncher() else {
            installState = .failed(InstallError.launcherMissing.description)
            return
        }
        installState = .working(.checking)
        do {
            let result = try await ProgramInstaller().install(
                file.url, options: InstallOptions(launcher: launcher),
                windowShown: { pid in
                    Task { @MainActor in Self.bringForward(pid) }
                },
                progress: { stage in
                    Task { @MainActor in
                        // Late progress messages must not hide the result.
                        if case .working = self.installState { self.installState = .working(stage) }
                    }
                })
            let engine = EngineCatalog.engine(id: result.manifest.engine) ?? EngineCatalog.default
            installState = .done(result.app, warning: EngineCheck.warning(result.missingImports, engine: engine))
        } catch {
            installState = .failed(String(describing: error))
        }
        refresh()
        refreshLibrary()
    }

    /// Brings the installer's window to the front. Wine windows open behind the active app, and
    /// macOS only lets the active app hand the front over: if the person moved on to another
    /// app meanwhile, the installer stays where it is.
    private static func bringForward(_ pid: pid_t) {
        guard NSApp.isActive, let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    // MARK: Library

    func refreshLibrary() {
        let folder = InstallOptions.defaultDestination
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        library = names.filter { $0.hasSuffix(".app") }.sorted().compactMap { name in
            let wrapper = Wrapper(url: folder.appendingPathComponent(name))
            guard let manifest = try? wrapper.readManifest() else { return nil }
            return LibraryApp(url: wrapper.url, name: name.replacingOccurrences(of: ".app", with: ""),
                              icon: NSWorkspace.shared.icon(forFile: wrapper.url.path), manifest: manifest)
        }
    }

    func openApp(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
