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
        /// The app, a warning if the engine lacks something the program uses, and the other
        /// programs the installer brought (a suite), which can become apps too.
        case done(URL, warning: String?, others: [ProgramChoice])
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

    private var installTask: Task<Void, Never>?

    /// Starts installing; `cancelInstall()` stops it.
    func startInstall(_ file: DroppedFile) {
        installTask?.cancel()
        installTask = Task { await install(file) }
    }

    /// Stops the installation: closes the installer and whatever it opened, and removes the
    /// half-built app. Back to the analysis, ready to try again.
    func cancelInstall() {
        installTask?.cancel()
    }

    /// Installs the dropped program and turns it into an app in ~/Applications.
    func install(_ file: DroppedFile) async {
        guard let launcher = InstallOptions.findLauncher() else {
            installState = .failed(InstallError.launcherMissing.description)
            return
        }
        installState = .working(.checking)
        installerWindows = []
        addedPrograms = []
        addProgramsError = nil
        do {
            let result = try await ProgramInstaller().install(
                file.url, options: InstallOptions(launcher: launcher),
                windowShown: { pid in
                    Task { @MainActor in
                        self.installerWindows.removeAll { $0 == pid }
                        self.installerWindows.append(pid)
                        Self.bringForward(pid)
                    }
                },
                progress: { stage in
                    Task { @MainActor in
                        // Late progress messages must not hide the result.
                        if case .working = self.installState { self.installState = .working(stage) }
                    }
                })
            let engine = EngineCatalog.engine(id: result.manifest.engine) ?? EngineCatalog.default
            installState = .done(result.app, warning: EngineCheck.warning(result.missingImports, engine: engine),
                                 others: result.otherPrograms)
        } catch is CancellationError {
            installState = .idle
        } catch {
            installState = Task.isCancelled ? .idle : .failed(String(describing: error))
        }
        installTask = nil
        refresh()
        refreshLibrary()
    }

    /// Other programs of a just installed app made into apps, by name.
    var addedPrograms: [String] = []
    var isAddingPrograms = false
    var addProgramsError: String?

    /// Makes an app for each chosen program, on the same Windows as `app`.
    func addPrograms(_ choices: [ProgramChoice], sharingWindowsOf app: URL) async {
        guard let launcher = InstallOptions.findLauncher() else {
            addProgramsError = InstallError.launcherMissing.description
            return
        }
        isAddingPrograms = true
        addProgramsError = nil
        for choice in choices where !addedPrograms.contains(choice.name) {
            do {
                _ = try await ProgramInstaller().addProgram(choice, sharingWindowsOf: app, launcher: launcher)
                addedPrograms.append(choice.name)
            } catch {
                addProgramsError = String(describing: error)
                break
            }
        }
        isAddingPrograms = false
        refreshLibrary()
    }

    /// Windows processes of the installer that opened a window, oldest first.
    private var installerWindows: [pid_t] = []

    /// "Show the installer": brings its newest window that is still open to the front. Wine
    /// windows open behind Vitral, and stay there if the person was in another app meanwhile.
    func showInstaller() {
        let open = WineWindows.owners()
        let pid = installerWindows.last { pid in open.contains { $0.pid == pid } }
            ?? open.first { WineWindows.looksLikeWindows($0.name) }?.pid
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
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

    /// Apps whose launcher was already checked against this Vitral's.
    private var launcherChecked: Set<URL> = []

    func refreshLibrary() {
        let folder = InstallOptions.defaultDestination
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let launcher = InstallOptions.findLauncher()
        library = names.filter { $0.hasSuffix(".app") }.sorted().compactMap { name in
            let wrapper = Wrapper(url: folder.appendingPathComponent(name))
            guard let manifest = try? wrapper.readManifest() else { return nil }
            // Apps made with an older Vitral are brought up to date once per session: the current
            // launcher, their Windows moved out of the app, and a signature that covers the app.
            if let launcher, launcherChecked.insert(wrapper.url).inserted {
                Self.bringUpToDate(wrapper, launcher: launcher)
            }
            return LibraryApp(url: wrapper.url, name: name.replacingOccurrences(of: ".app", with: ""),
                              icon: NSWorkspace.shared.icon(forFile: wrapper.url.path), manifest: manifest)
        }
    }

    /// Not while the app is open: its program is using the Windows that would move.
    private static func bringUpToDate(_ wrapper: Wrapper, launcher: URL) {
        let info = NSDictionary(contentsOf: wrapper.contents.appendingPathComponent("Info.plist"))
        if let id = info?["CFBundleIdentifier"] as? String,
           !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return }
        _ = try? wrapper.moveEmbeddedPrefix(to: .default)
        _ = try? wrapper.updateLauncher(from: launcher)
        if !FileManager.default.fileExists(atPath: wrapper.embeddedPrefix.path), !wrapper.hasValidSignature {
            try? wrapper.sign()
        }
    }

    /// Last uninstall error, shown in an alert.
    var uninstallError: String?

    /// Closes the program if it is open and moves the app and its logs to the Trash.
    func uninstall(_ app: LibraryApp) async {
        do {
            try await Uninstaller().uninstall(app.url)
        } catch {
            uninstallError = String(describing: error)
        }
        refreshLibrary()
    }

    /// Engine pieces no app uses, and their size on disk.
    var unusedEngineBytes: Int64 {
        EngineUsage.unusedComponents().reduce(0) { $0 + EngineUsage.folderSize(VitralHome.default.folder(of: $1)) }
    }

    /// Deletes the engine pieces no app uses. Returns the bytes freed.
    func removeUnusedEngines() -> Int64 {
        let freed = (try? EngineUsage.removeUnused()) ?? 0
        refresh()
        return freed
    }

    /// Library apps that were just opened and have no window yet. Windows programs take a few
    /// seconds to show one; the card says so meanwhile.
    private(set) var opening: Set<URL> = []

    func openApp(_ url: URL) {
        // Just installed: the library may not list it yet.
        if !library.contains(where: { $0.url == url }) { refreshLibrary() }
        // The program's file name, to recognize its window ("Shape it Level 1 PPlus.exe").
        let program = library.first(where: { $0.url == url })
            .map { ($0.manifest.program as NSString).lastPathComponent.lowercased() }
        let open = WineWindows.owners().filter { $0.name.lowercased() == program }
        // Already open (or another copy of the same program): no way to tell its new window.
        let watch = program != nil && open.isEmpty && !opening.contains(url)
        if watch { opening.insert(url) }

        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { launcher, _ in
            guard watch else { return }
            Task { @MainActor in
                await self.waitForWindow(of: program ?? "", launcher: launcher)
                self.opening.remove(url)
            }
        }
    }

    /// Waits until the program has a window, its launcher ends (it closed, or could not start;
    /// the launcher shows why) or a minute and a half passes.
    private func waitForWindow(of program: String, launcher: NSRunningApplication?) async {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, launcher?.isTerminated != true {
            if WineWindows.owners().contains(where: { $0.name.lowercased() == program }) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
