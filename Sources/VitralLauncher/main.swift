import AppKit
import VitralKit

// The launcher inside every app Vitral makes (`<Name>.app/Contents/MacOS/launcher`).
// It checks Rosetta and the engine, cleans what the recipes say, opens the Windows program,
// watches its start (and tries again if it crashes before showing a window), and keeps a log in
// ~/Library/Logs/Vitral/<Name>.log. It has no Dock icon: the program gets its own.

@MainActor
final class Launcher: NSObject, NSApplicationDelegate {
    private let wrapper = Wrapper(url: Bundle.main.bundleURL)
    private var launch: ProgramLaunch?
    private var log: FileHandle?
    private var logURL: URL?
    private var programPID: pid_t?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await start() }
    }

    /// Opening the app again while the program runs brings the program to the front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringProgramForward()
        return false
    }

    private func start() async {
        guard let launch = await prepare() else { return quit(1) }
        self.launch = launch
        // Named after the app itself, so two copies of a program keep separate logs.
        openLog(named: wrapper.url.deletingPathExtension().lastPathComponent)
        write("Vitral \(Vitral.version) · \(launch.manifest.name) · \(launch.manifest.program) · \(launch.manifest.engine)")

        // Already open (for example, the launcher was closed but the program was not): just show it.
        // Only if this app's Wine is running: another copy of the program (made with Vitral or
        // another tool) has windows with the same name.
        if launch.session.serverIsRunning, let running = launch.programWindowOwners().first {
            programPID = running
            write(tr("Ya estaba abierto: lo traigo al frente.", "Already open: bringing it forward."))
            bringProgramForward()
            return quit(0)
        }

        var attempt = 1
        while true {
            let removed = launch.clean()
            if removed > 0 { write(tr("Limpieza: \(removed) archivo(s)", "Cleanup: \(removed) file(s)")) }
            let offset = (try? log?.offset()) ?? 0
            let started = Date()
            write(tr("Abriendo (intento \(attempt))…", "Opening (attempt \(attempt))…"))

            let process = launch.makeProcess(log: log ?? .nullDevice)
            let watcher = Task { await watchForWindow(started: started) }
            let status = (try? await WineSession.wait(for: process)) ?? -1
            watcher.cancel()
            let sawWindow = await watcher.value
            let seconds = Date().timeIntervalSince(started)
            let attemptLog = readLog(from: offset)
            write(tr("Terminó a los \(Int(seconds)) s (código \(status), ventana: \(sawWindow ? "sí" : "no"))",
                     "Ended after \(Int(seconds)) s (status \(status), window: \(sawWindow ? "yes" : "no"))"))

            if StartupWatch.shouldRetry(ranFor: seconds, sawWindow: sawWindow, log: attemptLog, attempt: attempt) {
                write(tr("Se cayó al arrancar: vuelvo a intentar.", "It crashed while starting: trying again."))
                await launch.session.killServer()
                attempt += 1
                continue
            }
            if !sawWindow, seconds < StartupWatch.startupWindow, StartupWatch.looksLikeCrash(log: attemptLog) {
                showFailure()
            }
            break
        }
        quit(0)
    }

    /// Checks what the program needs, offering to install Rosetta if it is missing.
    private func prepare() async -> ProgramLaunch? {
        do {
            return try ProgramLaunch(wrapper: wrapper)
        } catch LaunchProblem.rosettaMissing {
            guard ask(LaunchProblem.rosettaMissing.description,
                      detail: tr("Rosetta es de Apple y traduce los programas de Windows para el chip de tu Mac. macOS te pedirá tu contraseña.",
                                 "Rosetta is Apple's and translates Windows programs for your Mac's chip. macOS will ask for your password."),
                      action: tr("Instalar Rosetta", "Install Rosetta")) else { return nil }
            await installRosetta()
            return MacSystem.hasRosetta ? await prepare() : nil
        } catch {
            tell(String(describing: error))
            return nil
        }
    }

    /// True once a window of the program is on screen.
    private func watchForWindow(started: Date) async -> Bool {
        while !Task.isCancelled {
            if let pid = launch?.programWindowOwners().first {
                programPID = pid
                bringProgramForward()
                write(tr("Ventana a los \(String(format: "%.1f", Date().timeIntervalSince(started))) s",
                         "Window after \(String(format: "%.1f", Date().timeIntervalSince(started))) s"))
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Wine windows open behind the active app. The launcher is active when the person opens
    /// the app, so it hands the front over to the program (if the person moved on to another
    /// app meanwhile, macOS ignores this and the program stays behind, as it should).
    private func bringProgramForward() {
        let pid = programPID ?? launch?.programWindowOwners().first
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    private func installRosetta() async {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        _ = try? await WineSession.wait(for: process)
    }

    // MARK: Log

    private func openLog(named name: String) {
        let folder = ProgramInstaller.logs
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Wrapper.safeName(name) + ".log")
        let previous = folder.appendingPathComponent(Wrapper.safeName(name) + " (anterior).log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logURL = url
        log = try? FileHandle(forWritingTo: url)
    }

    private func write(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        _ = try? log?.seekToEnd()
        log?.write(Data("[Vitral \(stamp)] \(line)\n".utf8))
    }

    private func readLog(from offset: UInt64) -> String {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    // MARK: Messages

    private func showFailure() {
        let name = launch?.manifest.name ?? wrapper.url.deletingPathExtension().lastPathComponent
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("\(name) se cerró al abrir", "\(name) closed while opening")
        alert.informativeText = tr("Lo intenté \(StartupWatch.maxAttempts) veces. El registro puede ayudar a encontrar la causa.",
                                   "I tried \(StartupWatch.maxAttempts) times. The log can help find the cause.")
        alert.addButton(withTitle: tr("Mostrar el registro", "Show the Log"))
        alert.addButton(withTitle: tr("Cerrar", "Close"))
        if alert.runModal() == .alertFirstButtonReturn, let logURL {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    private func ask(_ message: String, detail: String, action: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: tr("Cancelar", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func tell(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: tr("Aceptar", "OK"))
        alert.runModal()
    }

    private func quit(_ status: Int32) {
        try? log?.close()
        exit(status)
    }
}

let application = NSApplication.shared
let launcher = Launcher()
application.delegate = launcher
application.setActivationPolicy(.accessory)
application.run()
