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
        /// Path of its prefix (standardized), to tell whether something of it is running.
        let prefix: String
        /// Programs of its Windows that no app opens yet (a suite's other programs).
        var others: [ProgramChoice] = []
    }

    /// Apps of one installer (they share the same files and settings), shown together like a
    /// folder on iPhone: Encarta, Encarta Kids and Encarta Dictionaries; vMix and its title designer.
    struct LibraryGroup: Identifiable {
        var id: String { prefix }
        let prefix: String
        let name: String
        let apps: [LibraryApp]
    }

    /// A Windows installer or program the person dropped, already analyzed.
    struct DroppedFile: Identifiable {
        let id = UUID()
        let url: URL
        let report: InstallerReport
        let icon: NSImage?
        /// Known not to work yet (Paint.NET 5.1, Power BI…), from the installer's name and version.
        var knownIssues: [Diagnosis] = []
        /// A CD or DVD image: `report` and `icon` are then its installer's.
        var disc: Disc?

        struct Disc {
            let fileName: String
            let sizeBytes: Int64
            let label: String?
            /// "SETUP.EXE"
            let setupPath: String
        }
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

    /// The library as it is shown: each app alone, or with the others of its installer, where
    /// the first of them is.
    var libraryGroups: [LibraryGroup] {
        var order: [String] = []
        var byPrefix: [String: [LibraryApp]] = [:]
        for app in library {
            if byPrefix[app.prefix] == nil { order.append(app.prefix) }
            byPrefix[app.prefix, default: []].append(app)
        }
        return order.map { prefix in
            let apps = byPrefix[prefix] ?? []
            return LibraryGroup(prefix: prefix, name: Self.groupName(apps), apps: apps)
        }
    }

    /// The group shown open over the library, if any.
    var openGroup: String?

    /// What the apps' names begin with ("Encarta", "vMix"); otherwise the product most of them
    /// are, or the installer's name.
    static func groupName(_ apps: [LibraryApp]) -> String {
        guard let first = apps.first else { return "" }
        guard apps.count > 1 else { return first.name }
        let words = apps.map { $0.name.split(separator: " ").map(String.init) }
        var common: [String] = []
        for (index, word) in words[0].enumerated() {
            guard words.allSatisfy({ index < $0.count && $0[index].lowercased() == word.lowercased() }) else { break }
            common.append(word)
        }
        if !common.isEmpty { return common.joined(separator: " ") }
        let products = Dictionary(grouping: apps.compactMap { $0.manifest.product?.productName }, by: { $0 })
        if let product = products.max(by: { $0.value.count < $1.value.count }), product.value.count > 1 { return product.key }
        return first.manifest.installer.map { ($0 as NSString).deletingPathExtension } ?? first.name
    }

    let engine = EngineCatalog.default
    private let installer = ComponentInstaller()

    init() {
        refresh()
        refreshLibrary()
        showSetup = needsSetup
        // New known failures and fixes, without a new Vitral: once a day, if the person lets
        // Vitral look for updates by itself.
        Task.detached(priority: .background) {
            let store = CatalogStore()
            guard CatalogStore.automaticChecks, store.isDue(every: 86_400) else { return }
            _ = try? await store.refresh()
        }
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

    static let acceptedExtensions: Set<String> = Set(["exe", "msi", "zip"]).union(DiscImage.fileExtensions)

    func open(_ url: URL) {
        dropError = nil
        guard Self.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            dropError = String(localized: "Eso no parece un instalador de Windows. Vitral abre archivos .exe, .msi, .zip e .iso.")
            return
        }
        if DiscImage.fileExtensions.contains(url.pathExtension.lowercased()) {
            Task { await openDisc(url) }
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
            let known = Diagnoser.diagnose(.analysis(report), catalog: .current).filter { $0.kind == .notYet || $0.kind == .never }
            dropped = DroppedFile(url: url, report: report, icon: icon, knownIssues: known)
        } catch {
            dropError = String(localized: "No pude leer ese archivo.")
        }
    }

    /// A CD or DVD image: mounted for a moment, hidden, to show the installer it holds.
    private func openDisc(_ url: URL) async {
        do {
            let image = try InstallerAnalyzer.analyze(fileAt: url)
            guard image.kind == .discImage else {
                dropError = String(localized: "Ese archivo .iso no parece una imagen de CD o DVD.")
                return
            }
            let contents = try await DiscImage.contents(of: url, in: ProgramInstaller().staging)
            showSetup = false
            if case .working = installState {} else { installState = .idle }
            let known = Diagnoser.diagnose(.analysis(contents.setup), catalog: .current).filter { $0.kind == .notYet || $0.kind == .never }
            dropped = DroppedFile(url: url, report: contents.setup, icon: contents.icon.flatMap(NSImage.init(data:)),
                                  knownIssues: known,
                                  disc: .init(fileName: image.fileName, sizeBytes: image.sizeBytes, label: image.discLabel,
                                              setupPath: contents.setupPath))
        } catch let error as DiscImageError {
            dropError = error.description
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
        installStarted = Date()
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

    // MARK: Reports

    /// When the last installation began, to find its log for a report.
    private var installStarted = Date.distantPast

    /// The report for an installation that stopped with `message`.
    func installationReport(_ file: DroppedFile, message: String) async -> ProblemReport {
        let (installer, since) = (file.url, installStarted)
        return await Task.detached {
            ProblemReporter.installation(installer, message: message, log: ProgramInstaller.latestInstallLog(since: since))
        }.value
    }

    /// Known failures that may explain why an installation stopped.
    func installationDiagnoses(_ file: DroppedFile, message: String) async -> [Diagnosis] {
        let (installer, since, report) = (file.url, installStarted, file.report)
        return await Task.detached {
            Diagnoser.diagnose(.installation(report, fileName: installer.lastPathComponent, message: message,
                                             log: ProgramInstaller.latestInstallLog(since: since)), catalog: .current)
        }.value
    }

    /// The report for an app that does not work well (the person says how).
    func report(for app: LibraryApp) async -> ProblemReport {
        let url = app.url
        return await Task.detached { ProblemReporter.app(url) }.value
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
                              icon: NSWorkspace.shared.icon(forFile: wrapper.url.path), manifest: manifest,
                              prefix: wrapper.prefix(in: .default).standardizedFileURL.path,
                              others: (try? ProgramShortcuts.available(besides: wrapper.url)) ?? [])
        }
    }

    /// Last error making an app for another program of a Windows, shown in an alert.
    var addProgramError: String?

    /// An app being made from the library ("Add another program"), shown as a card until it is ready.
    struct PendingApp: Identifiable {
        var id: String { name }
        let name: String
        let icon: NSImage
    }
    private(set) var pendingApps: [PendingApp] = []

    /// "Add another program": makes an app for `choice`, on the same Windows as `app`.
    func addProgram(_ choice: ProgramChoice, to app: LibraryApp) async {
        guard let launcher = InstallOptions.findLauncher() else {
            addProgramError = InstallError.launcherMissing.description
            return
        }
        guard !pendingApps.contains(where: { $0.name == choice.name }) else { return }
        pendingApps.append(PendingApp(name: choice.name, icon: app.icon))
        do {
            _ = try await ProgramInstaller().addProgram(choice, sharingWindowsOf: app.url, launcher: launcher)
        } catch {
            addProgramError = String(describing: error)
        }
        // In the same update, so the new card replaces the pending one without a gap.
        refreshLibrary()
        pendingApps.removeAll { $0.name == choice.name }
    }

    /// Not while the app is open: its program is using the Windows that would move.
    private static func bringUpToDate(_ wrapper: Wrapper, launcher: URL) {
        let info = NSDictionary(contentsOf: wrapper.contents.appendingPathComponent("Info.plist"))
        if let id = info?["CFBundleIdentifier"] as? String,
           !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return }
        _ = try? wrapper.moveEmbeddedPrefix(to: .default)
        // A new launcher means a new Vitral: the icon, too, by its rules (once per version).
        if (try? wrapper.updateLauncher(from: launcher)) == true, let icns = ProgramInstaller.icns(for: wrapper),
           (try? wrapper.updateIcon(icns)) == true {
            NSWorkspace.shared.noteFileSystemChanged(wrapper.url.path)
        }
        if !FileManager.default.fileExists(atPath: wrapper.embeddedPrefix.path), !wrapper.hasValidSignature {
            try? wrapper.sign()
        }
    }

    /// Last uninstall error, shown in an alert.
    var uninstallError: String?

    /// Closes the program if it is open and moves the app and its logs to the Trash.
    /// Names of the other library apps on the same Windows as `app` (programs of one installer).
    func companions(of app: LibraryApp) -> [String] {
        Uninstaller.companions(of: app.url).map { $0.deletingPathExtension().lastPathComponent }
    }

    func uninstall(_ app: LibraryApp, withCompanions: Bool = false) async {
        do {
            if withCompanions {
                try await Uninstaller().uninstallWithCompanions(app.url)
            } else {
                try await Uninstaller().uninstall(app.url)
            }
        } catch {
            uninstallError = String(describing: error)
        }
        refreshLibrary()
    }

    // MARK: Force Quit

    /// Prefixes with some Windows process running: an open program, or one that hung.
    private(set) var openPrefixes: Set<String> = []
    /// Apps being force quit, shown as "Closing…" on their card.
    private(set) var quitting: Set<URL> = []
    /// Last force quit error, shown in an alert.
    var forceQuitError: String?

    /// Whether something of the app's Windows is running (it or another program of its installer).
    func isOpen(_ app: LibraryApp) -> Bool { openPrefixes.contains(app.prefix) }

    /// Looks for running Windows processes; the library calls it every few seconds.
    func refreshOpenApps() async {
        let open = await Task.detached { Set(WineProcesses.all().map(\.prefix)) }.value
        if open != openPrefixes { openPrefixes = open }
    }

    /// "Force Quit": closing a program from the Mac's menu waits for it to answer, with no time
    /// limit, so a hung one never closes. This ends everything of its Windows at once.
    func forceQuit(_ app: LibraryApp) async {
        quitting.insert(app.url)
        do {
            if try await !ForceQuit.quit(app.url) {
                forceQuitError = String(localized: "Algo de \(app.name) sigue abierto. Prueba otra vez o reinicia la Mac.")
            }
        } catch {
            forceQuitError = String(describing: error)
        }
        quitting.remove(app.url)
        opening.remove(app.url)
        await refreshOpenApps()
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

        let configuration = NSWorkspace.OpenConfiguration()
        // A Vitral started with another home (to test) opens its apps with that one too.
        if let home = ProcessInfo.processInfo.environment["VITRAL_HOME"], !home.isEmpty {
            configuration.environment = ["VITRAL_HOME": home]
        }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { launcher, _ in
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
