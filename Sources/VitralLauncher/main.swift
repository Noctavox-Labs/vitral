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

        // Its files cannot change while another program of the same Windows is open.
        if !sharedRunning, let withBrowser = await addBrowserIfNeeded(to: launch, loading: loading) {
            self.launch = withBrowser
        }
        if !sharedRunning, let move = await moveToNewerEngine(self.launch ?? launch, loading: loading) {
            engineMove = move
            self.launch = move.launch
        }

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
            let watcher = Task { [trial] in
                await watchForWindow(started: started, offset: offset, trying: trial, sharedRunning: sharedRunning)
            }
            // A fix that opens the program is saved once its first seconds pass without an error
            // box closing it (the watcher's answer), not when the program closes hours later.
            let keeper = Task { [trial, engineMove] in
                guard await watcher.value.opened else { return }
                if let engineMove { await keep(engineMove) }
                if let trial { await keep(trial) }
            }
            let status = (try? await WineSession.wait(for: process)) ?? -1
            watcher.cancel()
            let outcome = await watcher.value
            let sawWindow = outcome.opened
            hung = outcome == .hung
            await keeper.value
            let seconds = Date().timeIntervalSince(started)
            let attemptLog = readLog(from: offset)
            let errorBox = outcome == .errorBox
            write(tr("Terminó a los \(Int(seconds)) s (código \(status), ventana: \(sawWindow ? "sí" : "no")\(errorBox ? ", cuadro de error: sí" : ""))",
                     "Ended after \(Int(seconds)) s (status \(status), window: \(sawWindow ? "yes" : "no")\(errorBox ? ", error box: yes" : ""))"))

            if StartupWatch.shouldRetry(ranFor: seconds, sawWindow: sawWindow, log: attemptLog, attempt: attempt, errorBox: errorBox) {
                write(tr("Se cayó al arrancar: vuelvo a intentar.", "It crashed while starting: trying again."))
                loading.update(tr("Se cerró al arrancar. Vuelvo a intentar…", "It closed while starting. Trying again…"))
                loading.show(after: .zero)
                if !sharedRunning { await launch.session.killServer() }
                attempt += 1
                continue
            }
            guard hung || StartupWatch.failedToStart(ranFor: seconds, sawWindow: sawWindow, status: status, log: attemptLog,
                                                     errorBox: errorBox) else { break }

            // It did not open. A fix being tried did not help: back to how it was.
            if !sharedRunning { await launch.session.killServer() }
            // Nor with the newer engine: back to the previous one, and open it again with that.
            if let move = engineMove {
                await undo(move)
                loading.update(tr("No abrió con el motor nuevo. Vuelvo al anterior…", "It did not open with the newer engine. Going back to the previous one…"))
                loading.show(after: .zero)
                attempt = 1
                continue
            }
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

    // MARK: Engine

    /// An app moving to a newer build of its engine (cx26.3.0-1 → -2: the same Wine with Vitral's
    /// fixes), until the program shows whether it opens with it.
    private struct EngineMove {
        let previous: ProgramLaunch
        let launch: ProgramLaunch
        let backup: PrefixBackup?
    }
    private var engineMove: EngineMove?
    /// The newer engine this opening tried, with which the program did not open either.
    private var engineTried: String?

    /// Tries the engine that replaces the app's, if there is one and the program has not already
    /// failed with it: downloads it once, copies the prefix to go back (an APFS clone), and updates
    /// the prefix for it as Wine would, without Wine's offers to download Wine Mono.
    private func moveToNewerEngine(_ launch: ProgramLaunch, loading: LoadingPanel) async -> EngineMove? {
        let current = launch.manifest.engine
        guard let next = EngineCatalog.successor(of: current),
              !launch.manifest.recipes.contains(where: { $0.id == EngineCatalog.stayRecipe && $0.because == next.id }) else { return nil }
        write(tr("Hay un motor más nuevo: \(next.id) reemplaza a \(current). Lo pruebo.",
                 "There is a newer engine: \(next.id) replaces \(current). Trying it."))
        loading.update(tr("Actualizando el motor…", "Updating the engine…"))
        let components = ComponentInstaller(home: .default)
        do {
            for piece in next.components where !components.isInstalled(piece) {
                try await components.install(piece) { fraction in
                    Task { @MainActor in
                        loading.update(tr("Bajando el motor nuevo… \(Int(fraction * 100)) %", "Downloading the newer engine… \(Int(fraction * 100)) %"))
                    }
                }
            }
        } catch {
            write(tr("No pude bajar el motor nuevo: \(error). Sigo con el actual.", "Could not download the newer engine: \(error). Staying with this one."))
            return nil
        }
        let prefix = launch.session.prefix
        for old in PrefixBackup.leftovers(of: prefix) { try? FileManager.default.removeItem(at: old) }
        // Without a way back, the app stays as it is.
        guard let backup = makeBackup(of: prefix, scope: .everything) else { return nil }
        var manifest = launch.manifest
        manifest.engine = next.id
        do {
            loading.update(tr("Preparando el programa para el motor nuevo…", "Preparing the program for the newer engine…"))
            let moved = try ProgramLaunch(wrapper: wrapper, manifest: manifest)
            try await moved.session.updatePrefix()
            // The registry values of its recipes, in case the update changed one.
            let registry = manifest.settings.registry
            if !registry.isEmpty, !moved.session.registryContains(registry) { try await moved.session.importRegistry(registry) }
            return EngineMove(previous: launch, launch: moved, backup: backup)
        } catch {
            write(tr("No pude preparar el motor nuevo: \(error). Sigo con el actual.", "Could not prepare the newer engine: \(error). Staying with this one."))
            await launch.session.killServer()
            restore(backup)
            return nil
        }
    }

    /// The program opened with the newer engine: it stays, in this app and in the others of the
    /// same installer, which use the same files.
    private func keep(_ move: EngineMove) async {
        guard engineMove != nil else { return }
        engineMove = nil
        let wrapper = self.wrapper, manifest = move.launch.manifest, previous = move.previous.manifest.engine, backup = move.backup
        let problems = await Task.detached { () -> [String] in
            backup?.discard()
            var problems: [String] = []
            do { try wrapper.save(manifest) } catch { problems.append("\(wrapper.url.lastPathComponent): \(error)") }
            for app in Uninstaller.companions(of: wrapper.url) {
                let other = Wrapper(url: app)
                guard var theirs = try? other.readManifest(), theirs.engine == previous else { continue }
                theirs.engine = manifest.engine
                do { try other.save(theirs) } catch { problems.append("\(app.lastPathComponent): \(error)") }
            }
            return problems
        }.value
        write(problems.isEmpty
              ? tr("Abrió con el motor nuevo: queda \(manifest.engine).", "It opened with the newer engine: \(manifest.engine) stays.")
              : tr("Abrió con el motor nuevo, pero no pude guardarlo en: \(problems.joined(separator: "; "))",
                   "It opened with the newer engine, but could not save it in: \(problems.joined(separator: "; "))"))
    }

    /// It did not open with the newer engine: the files go back, and the app remembers not to try
    /// that engine again.
    private func undo(_ move: EngineMove) async {
        engineMove = nil
        write(tr("Con el motor nuevo no abrió: vuelvo a \(move.previous.manifest.engine).",
                 "It did not open with the newer engine: going back to \(move.previous.manifest.engine)."))
        restore(move.backup)
        engineTried = move.launch.manifest.engine
        var manifest = move.previous.manifest
        manifest.recipes.append(AppliedRecipe(id: EngineCatalog.stayRecipe, because: move.launch.manifest.engine))
        let wrapper = self.wrapper, kept = manifest
        let saved = await Task.detached { (try? wrapper.save(kept)) != nil }.value
        launch = saved ? ((try? ProgramLaunch(wrapper: wrapper, manifest: kept)) ?? move.previous) : move.previous
    }

    // MARK: Fixes

    /// Wine Gecko, for a program that shows pages with Internet Explorer's control in an app made
    /// before Vitral brought it (new apps get it while installing). The new launch, or nil if
    /// nothing changed. Without it the program still opens, with those pages blank.
    private func addBrowserIfNeeded(to launch: ProgramLaunch, loading: LoadingPanel) async -> ProgramLaunch? {
        let prefix = launch.session.prefix, program = launch.program
        let architecture = await Task.detached { () -> WineGecko.Architecture? in
            guard !WineGecko.isInstalled(prefix: prefix), WineGecko.usesBrowser(program: program) else { return nil }
            return WineGecko.architecture(of: PortableExecutable.parse(fileAt: program))
        }.value
        guard let architecture else { return nil }
        write(tr("El programa muestra páginas con el navegador de Internet Explorer: instalo Wine Gecko \(WineGecko.version) (\(architecture.rawValue)).",
                 "The program shows pages with Internet Explorer's browser: installing Wine Gecko \(WineGecko.version) (\(architecture.rawValue))."))
        loading.update(tr("Instalando el navegador que usa el programa…", "Installing the browser the program uses…"))
        loading.show(after: .zero)
        do {
            try await WineGecko.install(architecture, in: launch.session, home: .default, log: log ?? .nullDevice) { fraction in
                Task { @MainActor in
                    loading.update(tr("Instalando el navegador que usa el programa… \(Int(fraction * 100)) %",
                                      "Installing the browser the program uses… \(Int(fraction * 100)) %"))
                }
            }
        } catch {
            write(tr("No se pudo instalar Wine Gecko: \(error)", "Could not install Wine Gecko: \(error)"))
            return nil
        }
        var updated = launch.manifest
        updated.recipes.append(WineGecko.recipe(because: "\(launch.manifest.program) uses Internet Explorer's control"))
        let wrapper = self.wrapper, manifest = updated
        let saved = await Task.detached { () -> String? in
            do {
                try wrapper.save(manifest)
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
        if let saved {
            write(tr("Wine Gecko quedó instalado, pero no pude anotarlo en la app: \(saved)",
                     "Wine Gecko is installed, but could not note it in the app: \(saved)"))
        }
        // A new session: the one before kept Internet Explorer off.
        return try? ProgramLaunch(wrapper: wrapper, manifest: manifest)
    }

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

    /// How an attempt to open went, as far as the launcher can see while it runs.
    private enum Watch: Equatable {
        /// A window of the program is on screen.
        case window
        /// Running for a while without a window, and nothing wrong in its logs: a menu bar program.
        case menuBar
        /// Running without a window, and its logs show a known failure Vitral can do something
        /// about: the launcher closed it.
        case hung
        /// The program ended first.
        case ended
        /// The program ended having shown only error boxes.
        case errorBox

        var opened: Bool { self == .window || self == .menuBar }
    }

    /// Whether the last attempt was closed by the launcher because it hung without a window.
    private var hung = false

    /// Watches the attempt that started at `started` (its output in the log from `offset`).
    /// Error boxes it shows before a window of its own are not its window: if it shows only those
    /// and closes, it did not open (Encarta 2009's "Application cannot start").
    private func watchForWindow(started: Date, offset: UInt64, trying trial: Trial?, sharedRunning: Bool) async -> Watch {
        var boxes = StartupBoxes()
        var read = offset
        var opened = false
        func seconds() -> String { String(format: "%.1f", Date().timeIntervalSince(started)) }
        while !Task.isCancelled {
            if let launch {
                let (own, appeared) = boxes.look(at: launch.programWindows(), newBoxes: WineMessageBox.all(in: readNewLines(from: &read)))
                for (box, window) in appeared {
                    programPID = window.owner.pid
                    loading?.close()
                    bringProgramForward()
                    write(tr("Cuadro de error a los \(seconds()) s: «\(box.summary)»", "Error box after \(seconds()) s: «\(box.summary)»"))
                }
                if let own, !opened {
                    opened = true
                    programPID = own.owner.pid
                    loading?.close()
                    bringProgramForward()
                    write(tr("Ventana a los \(seconds()) s", "Window after \(seconds()) s"))
                }
            }
            if opened {
                // Its first seconds still count: a splash screen, then an error box, then
                // nothing is a failed start (Encarta 2009).
                if Date().timeIntervalSince(started) > StartupWatch.startupWindow, !boxes.busy() { return .window }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            // Programs that live in the menu bar (Greenshot) never show a window: running
            // for a while without one, it has opened. Unless its logs show it is stuck on a
            // failure Vitral knows (Qt that could not make its window, a crash): then it is closed
            // so a fix can be tried. Never with another program of the same installer open, which
            // would close too. The time counts from the last error box on screen.
            let quietSince = max(started, boxes.lastShowing ?? started)
            if Date().timeIntervalSince(quietSince) > StartupWatch.menuBarProgramDelay, let launch, launch.programIsRunning() {
                if !sharedRunning, let failure = await stuckOn(started: started, offset: offset, trying: trial) {
                    // It may have shown its window, or ended, while the logs were read.
                    guard !Task.isCancelled, launch.programIsRunning(), launch.programWindowOwners().isEmpty else { continue }
                    write(tr("Sin ventana a los \(Int(Date().timeIntervalSince(started))) s, y el registro muestra: \(failure.title) [\(failure.id)]. Lo cierro.",
                             "No window after \(Int(Date().timeIntervalSince(started))) s, and the log shows: \(failure.title) [\(failure.id)]. Closing it."))
                    await launch.session.killServer()
                    return .hung
                }
                guard !Task.isCancelled else { return .ended }
                loading?.close()
                write(tr("Abierto sin ventana a los \(Int(Date().timeIntervalSince(started))) s (¿en la barra de menú?)",
                         "Open without a window after \(Int(Date().timeIntervalSince(started))) s (in the menu bar?)"))
                return .menuBar
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // It ended.
        if boxes.closedOnBox(started: started, opened: opened) { return .errorBox }
        return opened ? .window : .ended
    }

    /// The known failure a program running without a window is stuck on, if there is one Vitral
    /// can act on: a crash (opening it again may work), the failure of a fix being tried (it was
    /// not enough), or a failure with a fix left to try. Hints that do not stop a program from
    /// opening (a missing GStreamer) do not count, nor anti-cheat, which shows up either way.
    private func stuckOn(started: Date, offset: UInt64, trying trial: Trial?) async -> Diagnosis? {
        guard let launch else { return nil }
        try? log?.synchronize()
        let attemptLog = readLog(from: offset)
        let catalog = await currentCatalog()
        let app = wrapper.url
        // Only what this attempt wrote: its part of Wine's log and the program's logs since it started.
        let observation = await Task.detached { () -> FailureObservation in
            let inspection = AppInspection(app: app, phase: .start)
            var observation = inspection.observation
            let programLogs = inspection.prefix.map {
                ProgramLogs.written(since: started, prefix: $0, programFolder: inspection.program?.deletingLastPathComponent())
            } ?? []
            observation.logs = [attemptLog] + programLogs.map { LogExcerpt.read($0, head: 64 * 1024, tail: 256 * 1024) }
            observation.status = nil
            observation.sawWindow = false
            return observation
        }.value
        let diagnoses = Diagnoser.diagnose(observation, catalog: catalog)
        if let crash = diagnoses.first(where: { $0.kind == .retry }) { return crash }
        let fixable = diagnoses.filter { $0.kind == .fixable }
        if trial != nil, let failure = fixable.first { return failure }
        let before = historyURL.map { RepairHistory.load(from: $0).tried(revision: catalog.revision, engine: launch.manifest.engine) } ?? []
        return RepairPlanner.plan(fixable, settings: launch.manifest.settings, prefix: launch.session.prefix,
                                  tried: Set(tried.map(\.key)).union(before)).first?.diagnosis
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

    /// The whole lines written since `offset`, which moves past them.
    private func readNewLines(from offset: inout UInt64) -> String {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return "" }
        let lines = data[data.startIndex...end]
        offset += UInt64(lines.count)
        return String(decoding: lines, as: UTF8.self)
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
        // What the program said, in its own words, before closing.
        let boxes = inspection.lastRun.flatMap { $0.errorBox ? $0.messageBoxes : nil } ?? []
        if let box = boxes.last {
            details.append(tr("El programa mostró este error: «\(box.summary)»", "The program showed this error: «\(box.summary)»"))
        }
        // What the engine lacks, as a possible cause. A program that explained its own error got
        // far enough to do so: whole DLLs it only loads on demand are optional ones, not the cause
        // (Encarta 2009's MOBB200.DLL asks for rockalldll.dll).
        let likely = boxes.isEmpty ? inspection.missing : inspection.missing.filter { !($0.delayLoaded && $0.function == nil) }
        if let known = diagnoses.first {
            details.append(known.title + ". " + known.explanation)
        } else if let launch, let explanation = EngineCheck.explanation(likely, engine: launch.session.engine.engine) {
            // A function the engine lacks is the cause Vitral can name (aTube Catcher on CrossOver 24).
            let newer = likely.contains { $0.function != nil } ? tr(" Hace falta un motor más nuevo.", " It needs a newer engine.") : ""
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
        if let engineTried {
            details.append(tr("También probé el motor más nuevo (\(engineTried)) y no abrió, así que sigue con el anterior.",
                              "I also tried the newer engine (\(engineTried)) and it did not open, so it keeps the previous one."))
        }
        if hung {
            details.append(tr("Seguía abierto sin ventana y el registro mostraba una falla, así que lo cerré.",
                              "It was still running without a window and its log showed a failure, so I closed it."))
        }
        details.append(attempts > 1
            ? tr("Lo intenté \(attempts) veces. El registro puede ayudar a encontrar la causa.",
                 "I tried \(attempts) times. The log can help find the cause.")
            : tr("El registro puede ayudar a encontrar la causa.", "The log can help find the cause."))
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = hung
            ? tr("\(name) no mostró su ventana", "\(name) did not show its window")
            : boxes.isEmpty ? tr("\(name) se cerró al abrir", "\(name) closed while opening")
            : tr("\(name) mostró un error al abrir", "\(name) showed an error while opening")
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
