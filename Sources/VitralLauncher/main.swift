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
    private var loading: LoadingPanel?
    /// Fixes tried in this opening, in order.
    private var tried: [Repair] = []
    /// Fixes already saved in the app in this opening.
    private var kept: Set<String> = []
    /// Fixes tried in an earlier opening without success, not tried again this time.
    private var triedBefore: [Repair] = []

    /// A fix being tried: what was there before, and the copy to go back to.
    private struct Trial {
        let repair: Repair
        let previous: ProgramLaunch
        let launch: ProgramLaunch
        let backup: PrefixBackup?
    }

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

        // Another program of the same Windows is open (MetaEditor next to MetaTrader 5): its
        // files and processes must be left alone.
        let sharedRunning = launch.session.serverIsRunning

        let loading = LoadingPanel(name: launch.manifest.name, icon: NSWorkspace.shared.icon(forFile: wrapper.url.path))
        self.loading = loading
        loading.show()

        var attempt = 1
        var trial: Trial?
        while true {
            let launch = self.launch ?? launch
            let removed = sharedRunning ? 0 : launch.clean()
            if removed > 0 { write(tr("Limpieza: \(removed) archivo(s)", "Cleanup: \(removed) file(s)")) }
            let offset = (try? log?.offset()) ?? 0
            let started = Date()
            write(tr("Abriendo (intento \(attempt))…", "Opening (attempt \(attempt))…"))

            let process = launch.makeProcess(log: log ?? .nullDevice)
            let watcher = Task { await watchForWindow(started: started) }
            // A fix that opens the program is saved as soon as the window shows, not when the
            // program closes hours later.
            let keeper = Task { [trial] in
                if let trial, await watcher.value { await keep(trial) }
            }
            let status = (try? await WineSession.wait(for: process)) ?? -1
            watcher.cancel()
            let sawWindow = await watcher.value
            await keeper.value
            let seconds = Date().timeIntervalSince(started)
            let attemptLog = readLog(from: offset)
            write(tr("Terminó a los \(Int(seconds)) s (código \(status), ventana: \(sawWindow ? "sí" : "no"))",
                     "Ended after \(Int(seconds)) s (status \(status), window: \(sawWindow ? "yes" : "no"))"))

            if StartupWatch.shouldRetry(ranFor: seconds, sawWindow: sawWindow, log: attemptLog, attempt: attempt) {
                write(tr("Se cayó al arrancar: vuelvo a intentar.", "It crashed while starting: trying again."))
                loading.update(tr("Se cerró al arrancar. Vuelvo a intentar…", "It closed while starting. Trying again…"))
                loading.show(after: .zero)
                if !sharedRunning { await launch.session.killServer() }
                attempt += 1
                continue
            }
            guard StartupWatch.failedToStart(ranFor: seconds, sawWindow: sawWindow, status: status, log: attemptLog) else { break }

            // It did not open. A fix being tried did not help: back to how it was.
            if !sharedRunning { await launch.session.killServer() }
            if let current = trial {
                undo(current)
                trial = nil
            }
            // A known failure with a fix Vitral can try by itself: try it and open again.
            if tried.count < RepairPlanner.maxRepairs, let next = await nextRepair(sharedRunning: sharedRunning) {
                tried.append(next)
                if let started = await begin(next) {
                    trial = started
                    self.launch = started.launch
                    loading.update(tr("No abrió. Pruebo un arreglo conocido…", "It did not open. Trying a known fix…"))
                    loading.show(after: .zero)
                    attempt = 1
                    continue
                }
            }
            loading.close()
            await showFailure(attempts: attempt)
            break
        }
        quit(0)
    }

    // MARK: Fixes

    /// The catalog the fixes come from, once looked up in this opening.
    private var catalog: FailureCatalog?

    /// The newest catalog: when a program does not open is when a new fix may help, so Vitral
    /// looks on GitHub (at most once an hour, five seconds at most, if the person lets it look
    /// for updates).
    private func currentCatalog() async -> FailureCatalog {
        if let catalog { return catalog }
        let store = CatalogStore()
        if CatalogStore.automaticChecks, store.isDue(every: 3600) {
            do {
                let found = try await store.refresh(timeout: 5)
                write(tr("Catálogo de fallas: revisión \(found.revision).", "Failure catalog: revision \(found.revision)."))
            } catch {
                write(tr("No pude buscar un catálogo de fallas nuevo: \(error)", "Could not look for a new failure catalog: \(error)"))
            }
        }
        let best = store.best()
        catalog = best
        return best
    }

    private var historyURL: URL? {
        launch.map { RepairHistory.url(app: wrapper.url, prefix: $0.session.prefix) }
    }

    /// Notes how a fix went, so the next openings do not try it again with this catalog and engine.
    private func remember(_ repair: Repair, _ outcome: RepairHistory.Outcome?) {
        guard let url = historyURL, let launch else { return }
        var history = RepairHistory.load(from: url)
        if let outcome {
            history.record(repair.key, outcome: outcome, revision: catalog?.revision ?? 0, engine: launch.manifest.engine)
        } else {
            history.forget(repair.key)
        }
        try? history.save(to: url)
    }

    /// The next fix for what the logs show, if Vitral can try one by itself.
    private func nextRepair(sharedRunning: Bool) async -> Repair? {
        guard let launch else { return nil }
        try? log?.synchronize()
        let catalog = await currentCatalog()
        let app = wrapper.url
        let inspection = await Task.detached { AppInspection(app: app, phase: .start) }.value
        let diagnoses = inspection.diagnoses(catalog: catalog)
        // Not again what did not help before, with this same catalog and engine.
        let before = historyURL.map { RepairHistory.load(from: $0).tried(revision: catalog.revision, engine: launch.manifest.engine) } ?? []
        let thisTime = Set(tried.map(\.key))
        let possible = RepairPlanner.plan(diagnoses, settings: launch.manifest.settings, prefix: launch.session.prefix, tried: thisTime)
        let repairs = possible.filter { !before.contains($0.key) }
        // Tried in an earlier opening (not this one), and not again until something changes.
        let earlier = possible.filter { before.contains($0.key) }
        if !earlier.isEmpty {
            triedBefore = earlier
            write(tr("Ya probé antes, sin éxito: \(earlier.map(\.key).joined(separator: ", ")). Vuelvo a probarlo con otro catálogo o motor.",
                     "Already tried before, without success: \(earlier.map(\.key).joined(separator: ", ")). I will try again with another catalog or engine."))
        }
        // While another program of the same installer is open, its files cannot be changed.
        return repairs.first { !sharedRunning || !$0.changesPrefix }
    }

    /// Applies a fix (with a copy to go back to). Nil if it could not, or the person said no.
    private func begin(_ repair: Repair) async -> Trial? {
        guard let launch else { return nil }
        let prefix = launch.session.prefix
        write(tr("Diagnóstico: \(repair.diagnosis.title) [\(repair.diagnosis.id)]. Pruebo: \(repair.description)",
                 "Diagnosis: \(repair.diagnosis.title) [\(repair.diagnosis.id)]. Trying: \(repair.description)"))
        for old in PrefixBackup.leftovers(of: prefix) {
            write(tr("Borro una copia que quedó de otra vez: \(old.lastPathComponent)", "Removing a copy left from another time: \(old.lastPathComponent)"))
            try? FileManager.default.removeItem(at: old)
        }
        var manifest = launch.manifest
        manifest.recipes.append(repair.recipe)
        var backup: PrefixBackup?

        if repair.component == "dotnet48" {
            loading?.close()
            guard ask(tr("\(launch.manifest.name) necesita .NET Framework", "\(launch.manifest.name) needs .NET Framework"),
                      detail: repair.diagnosis.explanation + "\n\n" + tr(
                        "Vitral baja de Microsoft los instaladores oficiales (unos 120 MB) y lo instala solo para este programa. Si después no abre, deja todo como estaba.",
                        "Vitral downloads Microsoft's official installers (about 120 MB) and installs it for this program only. If it still does not open, everything goes back as it was."),
                      action: tr("Instalar .NET Framework", "Install .NET Framework")) else {
                write(tr("No se instaló .NET Framework (la persona dijo que no).", "Did not install .NET Framework (the person said no)."))
                remember(repair, .declined)
                return nil
            }
            backup = makeBackup(of: prefix, scope: .everything)
            loading?.update(tr("Instalando .NET Framework 4.8…", "Installing .NET Framework 4.8…"))
            loading?.show(after: .zero)
            do {
                let loading = self.loading
                try await DotNetFramework.install(in: launch.session, home: .default, log: log ?? .nullDevice) { fraction in
                    Task { @MainActor in
                        loading?.update(tr("Instalando .NET Framework 4.8… \(Int(fraction * 100)) %", "Installing .NET Framework 4.8… \(Int(fraction * 100)) %"))
                    }
                }
            } catch {
                write(tr("No se pudo instalar .NET Framework: \(error)", "Could not install .NET Framework: \(error)"))
                await launch.session.killServer()
                restore(backup)
                remember(repair, .failed)
                return nil
            }
        } else if let settings = repair.settings {
            manifest.settings = settings
            let registry = launch.manifest.settings.registryMissing(from: settings)
            if !registry.isEmpty {
                backup = makeBackup(of: prefix, scope: .registry)
                do {
                    try await launch.session.importRegistry(registry)
                } catch {
                    write(tr("No se pudo cambiar el registro: \(error)", "Could not change the registry: \(error)"))
                    await launch.session.killServer()
                    restore(backup)
                    remember(repair, .failed)
                    return nil
                }
            }
        } else {
            return nil
        }
        do {
            return Trial(repair: repair, previous: launch, launch: try ProgramLaunch(wrapper: wrapper, manifest: manifest), backup: backup)
        } catch {
            write(String(describing: error))
            restore(backup)
            return nil
        }
    }

    private func makeBackup(of prefix: URL, scope: PrefixBackup.Scope) -> PrefixBackup? {
        do {
            return try PrefixBackup.make(of: prefix, scope: scope)
        } catch {
            write(tr("No pude copiar los archivos del programa para volver atrás: \(error)",
                     "Could not copy the program's files to go back: \(error)"))
            return nil
        }
    }

    private func restore(_ backup: PrefixBackup?) {
        guard let backup else { return }
        do {
            try backup.restore()
        } catch {
            write(tr("No pude volver a la copia (\(backup.copy.path)): \(error)", "Could not go back to the copy (\(backup.copy.path)): \(error)"))
        }
    }

    /// The fix did not help: the settings and files go back to how they were.
    private func undo(_ trial: Trial) {
        write(tr("El arreglo no alcanzó: lo deshago.", "The fix was not enough: undoing it."))
        launch = trial.previous
        restore(trial.backup)
        remember(trial.repair, .notEnough)
    }

    /// The fix opened the program: it stays in the app, with why.
    private func keep(_ trial: Trial) async {
        guard kept.insert(trial.repair.key).inserted else { return }
        let wrapper = self.wrapper, manifest = trial.launch.manifest, backup = trial.backup
        let saved = await Task.detached { () -> String? in
            backup?.discard()
            do {
                try wrapper.save(manifest)
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
        remember(trial.repair, nil)
        if let saved {
            write(tr("El arreglo funcionó, pero no pude guardarlo en la app: \(saved)", "The fix worked, but could not save it in the app: \(saved)"))
        } else {
            write(tr("El arreglo funcionó y quedó guardado en la app: \(trial.repair.recipe.id) [\(trial.repair.diagnosis.id)]",
                     "The fix worked and is saved in the app: \(trial.repair.recipe.id) [\(trial.repair.diagnosis.id)]"))
        }
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
                loading?.close()
                bringProgramForward()
                write(tr("Ventana a los \(String(format: "%.1f", Date().timeIntervalSince(started))) s",
                         "Window after \(String(format: "%.1f", Date().timeIntervalSince(started))) s"))
                return true
            }
            // Programs that live in the menu bar (Greenshot) never show a window: running
            // for a while without one, it has opened.
            if Date().timeIntervalSince(started) > StartupWatch.menuBarProgramDelay, let launch, launch.programIsRunning() {
                loading?.close()
                write(tr("Abierto sin ventana a los \(Int(Date().timeIntervalSince(started))) s (¿en la barra de menú?)",
                         "Open without a window after \(Int(Date().timeIntervalSince(started))) s (in the menu bar?)"))
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

    private func showFailure(attempts: Int) async {
        let name = launch?.manifest.name ?? wrapper.url.deletingPathExtension().lastPathComponent
        try? log?.synchronize()
        // What Vitral can tell: known failures in the logs (Wine's and the program's own), and
        // functions the engine lacks.
        let app = wrapper.url
        let inspection = await Task.detached { AppInspection(app: app, phase: .start) }.value
        inspection.missing.forEach { write($0.logLine) }
        let diagnoses = inspection.diagnoses(catalog: await currentCatalog())
        for diagnosis in diagnoses {
            write(tr("Diagnóstico: \(diagnosis.title) [\(diagnosis.id)]", "Diagnosis: \(diagnosis.title) [\(diagnosis.id)]"))
        }

        var details: [String] = []
        if let known = diagnoses.first {
            details.append(known.title + ". " + known.explanation)
        } else if let launch, let explanation = EngineCheck.explanation(inspection.missing, engine: launch.session.engine.engine) {
            // A function the engine lacks is the cause Vitral can name (aTube Catcher on CrossOver 24).
            let newer = inspection.missing.contains { $0.function != nil } ? tr(" Hace falta un motor más nuevo.", " It needs a newer engine.") : ""
            details.append(tr("Puede ser por esto: ", "This may be why: ") + explanation + "." + newer)
        }
        let triedText = tried.map(\.description)
        if !triedText.isEmpty {
            details.append(tr("Probé: \(triedText.joined(separator: "; ")). No alcanzó, así que lo dejé como estaba.",
                              "I tried: \(triedText.joined(separator: "; ")). It was not enough, so I left it as it was."))
        }
        let earlierText = triedBefore.map(\.description)
        if !earlierText.isEmpty {
            details.append(tr("En otra apertura ya probé: \(earlierText.joined(separator: "; ")). No alcanzó. Lo vuelvo a probar cuando Vitral tenga un catálogo de fallas o un motor nuevo.",
                              "Another time I already tried: \(earlierText.joined(separator: "; ")). It was not enough. I will try again once Vitral has a new failure catalog or engine."))
        }
        details.append(attempts > 1
            ? tr("Lo intenté \(attempts) veces. El registro puede ayudar a encontrar la causa.",
                 "I tried \(attempts) times. The log can help find the cause.")
            : tr("El registro puede ayudar a encontrar la causa.", "The log can help find the cause."))
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("\(name) se cerró al abrir", "\(name) closed while opening")
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: tr("Informar el problema…", "Report the Problem…"))
        alert.addButton(withTitle: tr("Mostrar el registro", "Show the Log"))
        alert.addButton(withTitle: tr("Cerrar", "Close"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? log?.synchronize()
            var report = await Task.detached { ProblemReporter.app(inspection, closedWhileOpening: attempts) }.value
            let allTried = (triedBefore + tried).map(\.key)
            if !allTried.isEmpty {
                report.facts.insert(.init(tr("Arreglos probados", "Fixes tried"), allTried.joined(separator: ", ")), at: 0)
            }
            review(report)
        case .alertSecondButtonReturn:
            if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        default:
            break
        }
    }

    /// Shows the report before anything leaves the Mac; the person can change it. Then GitHub's
    /// form opens filled in, where they decide whether to send it.
    private func review(_ report: ProblemReport) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        text.string = report.text
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = true
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        while true {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = tr("Informar el problema en GitHub", "Report the problem on GitHub")
            alert.informativeText = [
                report.title,
                report.summary,
                tr("Revisa el informe: no lleva tu nombre ni tus carpetas, pero puedes borrar o cambiar lo que quieras. Se abrirá el formulario de GitHub ya lleno en tu navegador; nada se publica hasta que lo envíes, y necesitas una cuenta de GitHub. Cuenta ahí qué viste; una captura de la ventana ayuda.",
                   "Check the report: it has neither your name nor your folders, but you can delete or change anything. GitHub's form will open filled in, in your browser; nothing is posted until you send it, and you need a GitHub account. Say there what you saw; a screenshot of the window helps."),
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
            alert.accessoryView = scroll
            alert.addButton(withTitle: tr("Abrir en GitHub", "Open in GitHub"))
            alert.addButton(withTitle: tr("Cancelar", "Cancel"))
            alert.addButton(withTitle: tr("¿Ya está reportado?", "Already Reported?"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(report.issueURL(text: text.string))
                return
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(report.searchURL)
            default:
                return
            }
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
