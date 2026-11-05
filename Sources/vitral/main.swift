import Foundation
import VitralKit

// `vitral` command-line tool. Every command has a Spanish and an English name.

// Show each line as soon as it is printed, also when the output goes to a pipe or a file
// (otherwise progress only appears when the command ends).
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print(tr(
        """
        Vitral \(Vitral.version): programas de Windows en tu Mac.

        Uso:
          vitral analizar [--json] <archivo>   Revisa un instalador o programa de Windows sin ejecutarlo.
          vitral analizar [--json] <carpeta>   Revisa un programa ya instalado: cuál abrir y con qué está hecho.
          vitral icono <programa.exe> <salida.icns|.ico>
                                               Saca el ícono de un programa de Windows.
          vitral motores                       Muestra los motores de Wine y si están instalados.
          vitral motores instalar [id]         Descarga y verifica un motor (el recomendado si no se indica).
          vitral motores limpiar               Borra los motores que ninguna app usa (se vuelven a bajar si hacen falta).
          vitral instalar <instalador> [--destino <carpeta>] [--nombre <nombre>] [--reemplazar]
                                               Instala un programa de Windows y lo deja como app de Mac
                                               (en ~/Applications si no se indica otra carpeta).
          vitral desinstalar <app>             Cierra el programa si está abierto y manda la app y sus registros a la
                                               Papelera. Tus archivos de Documentos, Descargas… no se tocan.
                                               Si otra app usa su mismo Windows, el Windows se queda.
          vitral programas <app>               Los otros programas del Windows de una app (los de una suite).
          vitral agregar <app> <programa>      Crea otra app para uno de esos programas, sobre el mismo Windows.
          vitral version                       Muestra la versión.

        Los comandos también funcionan en inglés (analyze, icon, engines install, engines clean, install, uninstall, programs, add). Idioma: VITRAL_LANG=es o en.
        """,
        """
        Vitral \(Vitral.version): Windows programs on your Mac.

        Usage:
          vitral analyze [--json] <file>     Inspect a Windows installer or program without running it.
          vitral analyze [--json] <folder>   Inspect an installed program: which file to open and what it is built with.
          vitral icon <program.exe> <output.icns|.ico>
                                             Extract the icon of a Windows program.
          vitral engines                     List the Wine engines and whether they are installed.
          vitral engines install [id]        Download and verify an engine (the recommended one by default).
          vitral engines clean               Delete the engines no app uses (downloaded again if needed).
          vitral install <installer> [--destination <folder>] [--name <name>] [--replace]
                                             Install a Windows program and turn it into a Mac app
                                             (in ~/Applications unless another folder is given).
          vitral uninstall <app>             Close the program if it is open and move the app and its logs to the
                                             Trash. Your files in Documents, Downloads… are not touched.
                                             If another app uses the same Windows, the Windows stays.
          vitral programs <app>              The other programs in an app's Windows (those of a suite).
          vitral add <app> <program>         Make another app for one of them, on the same Windows.
          vitral version                     Show the version.

        Commands also work in Spanish (analizar, icono, motores instalar, motores limpiar, instalar, desinstalar, programas, agregar). Language: VITRAL_LANG=en or es.
        """
    ))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func describeKind(_ report: InstallerReport) -> String {
    let version = report.kindVersion.map { " " + $0 } ?? ""
    switch report.kind {
    case .innoSetup: return tr("Instalador Inno Setup\(version)", "Inno Setup installer\(version)")
    case .nsis:
        let builder = report.builder == .electronBuilder ? tr(", hecho con electron-builder", ", made with electron-builder") : ""
        return tr("Instalador NSIS\(version)", "NSIS installer\(version)") + builder
    case .msi: return tr("Paquete de Windows Installer (.msi)", "Windows Installer package (.msi)")
    case .wixBurn: return tr("Instalador WiX Burn (paquete de varios instaladores)", "WiX Burn bundle (installs several packages)")
    case .installShield: return tr("Instalador InstallShield", "InstallShield installer")
    case .sevenZipSFX: return tr("Archivo 7-Zip autoextraíble", "7-Zip self-extracting archive")
    case .zip: return tr("Archivo ZIP (hay que descomprimirlo y buscar el programa)", "ZIP archive (unpack it and look for the program)")
    case .executable:
        if report.executable?.isDLL == true {
            return tr("Biblioteca de Windows (DLL): no se abre sola", "Windows library (DLL): it does not run on its own")
        }
        return tr("Programa de Windows (no es un instalador conocido)", "Windows program (not a known installer)")
    case .unknown: return tr("No parece un instalador ni un programa de Windows", "Does not look like a Windows installer or program")
    }
}

func describeExecutable(_ info: ExecutableInfo) -> String {
    switch info.format {
    case .dos:
        return tr("Programa de MS-DOS (Vitral no lo puede abrir)", "MS-DOS program (Vitral cannot run it)")
    case .windows16:
        return tr("Windows de 16 bits (Wine en Mac no lo puede abrir)", "16-bit Windows (Wine on Mac cannot run it)")
    case .pe32, .pe32Plus:
        let kind: String
        switch (info.isDLL, info.subsystem) {
        case (true, _): kind = tr("biblioteca (DLL)", "library (DLL)")
        case (false, .gui?): kind = tr("con interfaz gráfica", "graphical")
        case (false, .console?): kind = tr("de consola", "console")
        default: kind = tr("de otro tipo", "other type")
        }
        let arm = info.machine == .arm64 || info.machine == .arm
        let machine = arm ? " · ARM" : ""
        return tr("Windows de \(info.bits) bits, \(kind)\(machine)", "\(info.bits)-bit Windows, \(kind)\(machine)")
    }
}

func describeProduct(_ version: VersionInfo?) -> String? {
    guard let version, let name = version.productName ?? version.fileDescription else { return nil }
    var text = name
    if let number = version.productVersion ?? version.fileVersion { text += " " + number }
    if let company = version.companyName { text += " · " + company }
    return text
}

func describeTechnology(_ technology: Technology) -> String {
    let version = technology.version.map { " " + $0 } ?? ""
    switch technology.kind {
    case .qt: return "Qt\(version)"
    case .qtQuick: return "Qt Quick (QML)"
    case .qtWebEngine: return tr("navegador QtWebEngine (Chromium)", "QtWebEngine browser (Chromium)")
    case .angle: return "ANGLE (OpenGL ES → Direct3D)"
    case .electron: return "Electron\(version)"
    case .cef: return "CEF (Chromium)\(version)"
    case .dotNetFramework: return ".NET Framework\(version)"
    case .dotNet: return ".NET\(version)"
    case .java: return "Java"
    case .unity: return "Unity\(version)"
    case .unreal: return "Unreal Engine"
    case .visualCpp: return "Visual C++\(version)"
    }
}

func describeGraphics(_ api: GraphicsAPI) -> String {
    switch api {
    case .directDraw: "DirectDraw"
    case .direct3D8: "Direct3D 8"
    case .direct3D9: "Direct3D 9"
    case .direct3D10: "Direct3D 10"
    case .direct3D11: "Direct3D 11"
    case .direct3D12: "Direct3D 12"
    case .openGL: "OpenGL"
    case .vulkan: "Vulkan"
    }
}

func describeAntiCheat(_ antiCheat: AntiCheat) -> String {
    switch antiCheat {
    case .easyAntiCheat: "Easy Anti-Cheat"
    case .battlEye: "BattlEye"
    case .gameGuard: "nProtect GameGuard"
    case .xigncode: "XIGNCODE3"
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

func analyzeFolder(_ url: URL, json: Bool) {
    let report: ProgramReport
    do {
        report = try ProgramAnalyzer.analyze(folderAt: url)
    } catch {
        fail(tr("No pude revisar la carpeta: \(url.path)", "Could not inspect the folder: \(url.path)"))
    }
    if json { return printJSON(report) }

    let files = tr("\(report.fileCount) archivos", "\(report.fileCount) files")
    print("\(report.folderName)  (" + tr("carpeta", "folder") + " · \(files) · \(formatSize(report.totalBytes)))")

    guard let main = report.mainExecutable, let info = report.executable else {
        print("  " + tr("No encontré ningún programa de Windows para abrir.", "Found no Windows program to open."))
        return
    }
    let pad = "               "
    print("  " + tr("Programa:    ", "Program:     ") + main)
    let icon = info.hasIcon ? tr(" · con ícono", " · has an icon") : tr(" · sin ícono", " · no icon")
    print(pad + describeExecutable(info) + icon)
    if let product = describeProduct(info.version) {
        print("  " + tr("Producto:    ", "Product:     ") + product)
    }

    let runtimes: Set<Technology.Kind> = [.visualCpp, .dotNetFramework, .dotNet, .java]
    let built = report.technologies.filter { !runtimes.contains($0.kind) }
    if !built.isEmpty {
        print("  " + tr("Hecho con:   ", "Built with:  ") + built.map(describeTechnology).joined(separator: " · "))
    }
    var needs = report.technologies.filter { runtimes.contains($0.kind) }.map { technology -> String in
        technology.kind == .visualCpp
            ? describeTechnology(technology) + tr(" de \(info.bits) bits", " (\(info.bits)-bit)")
            : describeTechnology(technology)
    }
    if !report.bundledRedistributables.isEmpty {
        let names = report.bundledRedistributables.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        needs.append(tr("(trae \(names))", "(ships \(names))"))
    }
    if !needs.isEmpty {
        print("  " + tr("Necesita:    ", "Needs:       ") + needs.joined(separator: " "))
    }
    if !report.graphics.isEmpty {
        print("  " + tr("Gráficos:    ", "Graphics:    ") + report.graphics.map(describeGraphics).joined(separator: " · "))
    }
    if !report.antiCheat.isEmpty {
        let names = report.antiCheat.map(describeAntiCheat).joined(separator: ", ")
        print("  " + tr("Antitrampas: ", "Anti-cheat:  ") + names)
        print(pad + tr("No funciona con Wine en Mac; Vitral no lo va a esquivar.",
                       "It does not work with Wine on Mac; Vitral will not bypass it."))
    }
    if !report.alternatives.isEmpty {
        print("  " + tr("Otros:       ", "Others:      ") + report.alternatives.joined(separator: ", "))
    }
    // A folder inside a prefix also counts the DLLs installed in its Windows folder.
    var prefix: URL?
    var folder = url.standardizedFileURL
    while folder.pathComponents.count > 1 {
        if folder.lastPathComponent == "drive_c" { prefix = folder.deletingLastPathComponent(); break }
        folder = folder.deletingLastPathComponent()
    }
    printEngineCheck(program: url.appendingPathComponent(main), prefix: prefix, label: tr("Motor:       ", "Engine:      "))
}

/// What the default engine lacks of what the program uses. Only if the engine is downloaded.
func printEngineCheck(program: URL, prefix: URL?, label: String) {
    let engine = EngineCatalog.default
    let pad = String(repeating: " ", count: label.count + 2)
    guard engine.components.allSatisfy(ComponentInstaller().isInstalled) else {
        print("  " + label + tr("(descarga el motor para revisar si tiene todo lo que usa el programa)",
                                "(download the engine to check whether it has everything the program uses)"))
        return
    }
    let missing = EngineCheck.missingImports(program: program, engine: InstalledEngine(engine: engine), prefix: prefix)
    guard !missing.isEmpty else {
        return print("  " + label + tr("\(engine.name) tiene todas las funciones de Windows que usa",
                                       "\(engine.name) has every Windows function it uses"))
    }
    print("  " + label + tr("\(engine.name) no tiene todo lo que usa (\(missing.count)):",
                            "\(engine.name) lacks some of what it uses (\(missing.count)):"))
    let shown = 15
    for item in missing.prefix(shown) { print(pad + item.logLine) }
    if missing.count > shown { print(pad + tr("y \(missing.count - shown) más", "and \(missing.count - shown) more")) }
}

func extractIcon(_ options: [String]) {
    guard options.count == 2 else {
        printUsage()
        exit(2)
    }
    let input = URL(fileURLWithPath: (options[0] as NSString).expandingTildeInPath)
    let output = URL(fileURLWithPath: (options[1] as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: input, options: .alwaysMapped) else {
        fail(tr("No pude leer el archivo: \(options[0])", "Could not read the file: \(options[0])"))
    }
    guard let ico = PortableExecutable.icon(data) else {
        fail(tr("Ese programa no tiene ícono.", "That program has no icon."))
    }
    let wantsICNS = output.pathExtension.lowercased() != "ico"
    guard let result = wantsICNS ? AppIcon.icns(fromICO: ico) : ico else {
        fail(tr("No pude convertir el ícono.", "Could not convert the icon."))
    }
    do {
        try result.write(to: output)
    } catch {
        fail(tr("No pude guardar \(output.path): \(error.localizedDescription)",
                "Could not save \(output.path): \(error.localizedDescription)"))
    }
    print(tr("Ícono guardado en \(output.path)", "Icon saved to \(output.path)"))
}

func engines(_ options: [String]) async {
    let installer = ComponentInstaller()
    if let action = options.first, ["instalar", "install"].contains(action) {
        let id = options.dropFirst().first ?? EngineCatalog.default.id
        guard let engine = EngineCatalog.engine(id: id) else {
            fail(tr("No conozco el motor «\(id)». Mira la lista con: vitral motores",
                    "Unknown engine “\(id)”. See the list with: vitral engines"))
        }
        for piece in engine.components {
            if installer.isInstalled(piece) {
                print(tr("✓ \(piece.name): ya estaba", "✓ \(piece.name): already installed"))
                continue
            }
            print(tr("Descargando \(piece.name) (\(formatSize(piece.bytes)))…", "Downloading \(piece.name) (\(formatSize(piece.bytes)))…"))
            print("  " + piece.url.absoluteString)
            do {
                let folder = try await installer.install(piece)
                print(tr("✓ Verificado (SHA-256) e instalado en \(folder.path)", "✓ Verified (SHA-256) and installed in \(folder.path)"))
            } catch {
                fail("✗ " + String(describing: error))
            }
        }
        if !MacSystem.hasRosetta {
            print(tr("Ojo: falta Rosetta, y Wine la necesita. Instálala con: softwareupdate --install-rosetta",
                     "Note: Rosetta is missing and Wine needs it. Install it with: softwareupdate --install-rosetta"))
        }
        return
    }
    if let action = options.first, ["limpiar", "clean"].contains(action) {
        let unused = EngineUsage.unusedComponents()
        if unused.isEmpty {
            print(tr("No hay motores sin usar.", "No unused engines."))
            return
        }
        do {
            for piece in unused { print(tr("Borrando \(piece.name)…", "Deleting \(piece.name)…")) }
            let freed = try EngineUsage.removeUnused()
            print(tr("✓ Liberados \(formatSize(freed)).", "✓ Freed \(formatSize(freed))."))
        } catch {
            fail("✗ " + String(describing: error))
        }
        return
    }
    guard options.isEmpty else {
        printUsage()
        exit(2)
    }

    print(tr("Motores de Wine:", "Wine engines:"))
    for engine in EngineCatalog.all {
        let ready = engine.components.allSatisfy(installer.isInstalled)
        let mark = engine.id == EngineCatalog.default.id ? tr(" (recomendado)", " (recommended)") : ""
        let state = ready ? tr("instalado", "installed") : tr("sin instalar", "not installed")
        print("  \(engine.id)  \(engine.name)\(mark) · \(state)")
        for piece in engine.components {
            let pieceState = installer.isInstalled(piece) ? "✓" : "·"
            print("      \(pieceState) \(piece.name) · \(formatSize(piece.bytes)) · \(piece.license)")
        }
    }
    print("Rosetta: " + (MacSystem.hasRosetta ? tr("instalada", "installed")
                                              : tr("falta (softwareupdate --install-rosetta)", "missing (softwareupdate --install-rosetta)")))
}

func analyze(_ options: [String]) {
    let json = options.contains("--json")
    let paths = options.filter { $0 != "--json" }
    guard paths.count == 1 else {
        printUsage()
        exit(2)
    }

    let url = URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return analyzeFolder(url, json: json)
    }
    let report: InstallerReport
    do {
        report = try InstallerAnalyzer.analyze(fileAt: url)
    } catch InstallerAnalyzerError.notFound {
        fail(tr("No encontré el archivo: \(paths[0])", "File not found: \(paths[0])"))
    } catch {
        fail(tr("No pude leer el archivo: \(error.localizedDescription)", "Could not read the file: \(error.localizedDescription)"))
    }

    if json { return printJSON(report) }

    print("\(report.fileName)  (\(formatSize(report.sizeBytes)))")
    print("  " + tr("Tipo:     ", "Type:     ") + describeKind(report))
    if let info = report.executable {
        let label = report.kind == .executable ? tr("Programa: ", "Program:  ") : tr("Archivo:  ", "File:     ")
        print("  " + label + describeExecutable(info) + (report.kind == .executable ? "" : tr(" (el instalador)", " (the installer)")))
        if let bits = report.programBits {
            print("  " + tr("Programa: ", "Program:  ") + tr("Windows de \(bits) bits", "\(bits)-bit Windows"))
        }
        if let product = describeProduct(info.version) {
            let label = report.kind == .executable ? tr("Producto: ", "Product:  ") : tr("Instala:  ", "Installs: ")
            print("  " + label + product)
        }
    }
    if !report.companionFiles.isEmpty {
        let folder = url.deletingLastPathComponent()
        let list = report.companionFiles.map { name -> String in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
            return size.map { "\(name) (\(formatSize($0)))" } ?? name
        }
        print("  " + tr("Necesita: ", "Needs:    ") + list.joined(separator: ", "))
        print("            " + tr("(tienen que estar en la misma carpeta)", "(they must stay in the same folder)"))
    }
    for recipe in Recipes.installerSettings(for: report).applied {
        print("  " + tr("Ajuste:   ", "Setting:  ") + Recipes.describe(recipe.id))
    }
    // An installer carries the program packed inside: it can only be checked once installed.
    if report.kind == .executable, report.executable?.bits ?? 0 >= 32 {
        printEngineCheck(program: url, prefix: nil, label: tr("Motor:    ", "Engine:   "))
    }
}

func install(_ options: [String]) async {
    var paths: [String] = []
    var destination = InstallOptions.defaultDestination
    var name: String?
    var replace = false
    var index = 0
    func value() -> String {
        index += 1
        guard index < options.count else { printUsage(); exit(2) }
        return options[index]
    }
    while index < options.count {
        switch options[index] {
        case "--destino", "--destination": destination = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
        case "--nombre", "--name": name = value()
        case "--reemplazar", "--replace": replace = true
        default: paths.append(options[index])
        }
        index += 1
    }
    guard paths.count == 1 else {
        printUsage()
        exit(2)
    }
    guard let launcher = InstallOptions.findLauncher() else { fail(InstallError.launcherMissing.description) }
    let installer = URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath)

    // Ctrl-C: Wine keeps running on its own, so stop it before leaving.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        print(tr("\nCancelando…", "\nCancelling…"))
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "Vitral/Staging/"]
        try? kill.run()
        kill.waitUntilExit()
        exit(130)
    }
    interrupt.resume()

    let lastStage = Locked<InstallStage?>(nil)
    let progress: @Sendable (InstallStage) -> Void = { stage in
        if case .downloadingEngine(let fraction) = stage {
            let percent = Int(fraction * 100)
            if case .downloadingEngine(let old) = lastStage.value, Int(old * 100) / 10 == percent / 10 { return }
            lastStage.value = stage
            print(tr("  Descargando el motor… \(percent) %", "  Downloading the engine… \(percent) %"))
            return
        }
        lastStage.value = stage
        switch stage {
        case .checking: print(tr("1/6 Revisando el instalador…", "1/6 Checking the installer…"))
        case .downloadingEngine: break
        case .preparingWindows: print(tr("2/6 Preparando Windows (la primera vez tarda un poco)…", "2/6 Preparing Windows (the first time takes a while)…"))
        case .runningInstaller:
            print(tr("3/6 Abriendo el instalador: sigue sus pasos en su ventana.",
                     "3/6 Opening the installer: follow its steps in its window."))
            print(tr("    Si no la ves, puede estar detrás de esta: búscala en el Dock.",
                     "    If you do not see it, it may be behind this one: look for it in the Dock."))
            print(tr("    Si al terminar abre el programa, Vitral lo cierra y sigue.",
                     "    If it opens the program when it finishes, Vitral closes it and goes on."))
        case .finishingInstaller: print(tr("    El instalador terminó.", "    The installer finished."))
        case .closingProgram: print(tr("    El instalador abrió el programa: lo cierro para terminar la app.",
                                       "    The installer opened the program: closing it to finish the app."))
        case .copyingProgram: print(tr("3/6 Copiando el programa…", "3/6 Copying the program…"))
        case .findingProgram: print(tr("4/6 Buscando el programa instalado…", "4/6 Looking for the installed program…"))
        case .applyingSettings: print(tr("5/6 Aplicando los ajustes recomendados…", "5/6 Applying the recommended settings…"))
        case .buildingApp: print(tr("6/6 Armando la app…", "6/6 Building the app…"))
        }
    }

    do {
        let result = try await ProgramInstaller().install(
            installer, options: InstallOptions(destination: destination, name: name, launcher: launcher, replace: replace),
            progress: progress)
        print("")
        print(tr("Listo: ", "Done: ") + result.app.path)
        print("  " + tr("Programa: ", "Program:  ") + result.manifest.program)
        if let main = result.report.executable { print("            " + describeExecutable(main)) }
        let technologies = result.report.technologies.map(describeTechnology)
        if !technologies.isEmpty { print("  " + tr("Hecho con: ", "Built with: ") + technologies.joined(separator: " · ")) }
        for recipe in result.manifest.recipes {
            print("  " + tr("Ajuste: ", "Setting: ") + Recipes.describe(recipe.id) + " (\(recipe.because))")
        }
        if let warning = EngineCheck.warning(result.missingImports, engine: EngineCatalog.engine(id: result.manifest.engine) ?? EngineCatalog.default) {
            print("  " + warning)
        }
        if !result.report.antiCheat.isEmpty {
            print(tr("  Ojo: tiene antitrampas (\(result.report.antiCheat.map(describeAntiCheat).joined(separator: ", "))). Lo más probable es que no funcione con Wine; Vitral no lo elude.",
                     "  Note: it has anti-cheat (\(result.report.antiCheat.map(describeAntiCheat).joined(separator: ", "))). It will most likely not work with Wine; Vitral does not bypass it."))
        }
        print(tr("Ábrela con doble clic o con: open \"\(result.app.path)\"", "Open it with a double click or with: open \"\(result.app.path)\""))
        if !result.otherPrograms.isEmpty {
            print(tr("El instalador también trae:", "The installer also brought:"))
            for other in result.otherPrograms { print("  \(other.name)  (\(other.program))") }
            print(tr("Para tenerlo como app: vitral agregar \"\(result.app.path)\" \"<programa>\"",
                     "To have it as an app: vitral add \"\(result.app.path)\" \"<program>\""))
        }
    } catch {
        fail("✗ " + String(describing: error))
    }
}

/// An app given on the command line: a path, or a bare name for the app in ~/Applications.
func appURL(_ argument: String) -> URL {
    var path = (argument as NSString).expandingTildeInPath
    if !path.contains("/") {
        path = InstallOptions.defaultDestination.appendingPathComponent(path.hasSuffix(".app") ? path : path + ".app").path
    }
    return URL(fileURLWithPath: path)
}

func listPrograms(_ options: [String]) {
    guard options.count == 1 else { printUsage(); exit(2) }
    let app = appURL(options[0])
    do {
        let choices = try ProgramShortcuts.available(besides: app)
        if choices.isEmpty {
            print(tr("Su Windows no tiene otros programas con acceso directo.", "Its Windows has no other programs with a shortcut."))
        }
        for choice in choices { print("\(choice.name)  (\(choice.program))") }
    } catch {
        fail("✗ " + String(describing: error))
    }
}

func addProgram(_ options: [String]) async {
    guard options.count == 2 else { printUsage(); exit(2) }
    let app = appURL(options[0])
    guard let launcher = InstallOptions.findLauncher() else { fail(InstallError.launcherMissing.description) }
    do {
        let choices = try ProgramShortcuts.available(besides: app)
        let wanted = options[1].lowercased()
        guard let choice = choices.first(where: { $0.name.lowercased() == wanted })
                ?? choices.first(where: { $0.name.lowercased().contains(wanted) }) else {
            fail(tr("✗ No encuentro «\(options[1])». Los programas que se pueden agregar: ",
                    "✗ I cannot find \"\(options[1])\". Programs that can be added: ")
                 + (choices.isEmpty ? "—" : choices.map(\.name).joined(separator: ", ")))
        }
        let added = try await ProgramInstaller().addProgram(choice, sharingWindowsOf: app, launcher: launcher)
        print(tr("✓ \(choice.name): \(added.path) (comparte el Windows de \(app.deletingPathExtension().lastPathComponent))",
                 "✓ \(choice.name): \(added.path) (shares the Windows of \(app.deletingPathExtension().lastPathComponent))"))
    } catch {
        fail("✗ " + String(describing: error))
    }
}

func uninstall(_ options: [String]) async {
    guard options.count == 1 else {
        printUsage()
        exit(2)
    }
    let app = appURL(options[0])
    do {
        let trashed = try await Uninstaller().uninstall(app)
        print(tr("✓ A la Papelera (se puede recuperar desde ahí):", "✓ Moved to the Trash (you can put it back from there):"))
        for item in trashed { print("  " + item.path) }
    } catch {
        fail("✗ " + String(describing: error))
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

guard let command = arguments.first else {
    printUsage()
    exit(0)
}

switch command {
case "analizar", "analyze":
    analyze(Array(arguments.dropFirst()))
case "icono", "icon":
    extractIcon(Array(arguments.dropFirst()))
case "motores", "engines", "motor", "engine":
    await engines(Array(arguments.dropFirst()))
case "instalar", "install":
    await install(Array(arguments.dropFirst()))
case "desinstalar", "uninstall":
    await uninstall(Array(arguments.dropFirst()))
case "programas", "programs":
    listPrograms(Array(arguments.dropFirst()))
case "agregar", "add":
    await addProgram(Array(arguments.dropFirst()))
case "version", "versión", "--version", "-v":
    print("Vitral \(Vitral.version)")
case "ayuda", "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data((tr("Comando desconocido: ", "Unknown command: ") + command + "\n\n").utf8))
    printUsage()
    exit(2)
}
