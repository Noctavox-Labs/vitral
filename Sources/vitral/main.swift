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
                          [--argumentos "<argumentos del instalador>"]
                                               Instala un programa de Windows y lo deja como app de Mac
                                               (en ~/Applications si no se indica otra carpeta). --argumentos
                                               pasa opciones al instalador, como "/VERYSILENT" de Inno Setup.
          vitral desinstalar [--todas] <app>   Cierra el programa si está abierto y manda la app y sus registros a la
                                               Papelera. Tus archivos de Documentos, Descargas… no se tocan.
                                               Si otra app vino del mismo instalador, los archivos y ajustes que
                                               comparten se quedan; con --todas se van esas apps y todo.
          vitral programas <app>               Los otros programas que trajo el instalador de una app (una suite).
          vitral agregar <app> <programa>      Crea otra app para uno de esos programas (comparten archivos y ajustes).
          vitral informe [--abrir|--enlace] <app>
                                               Muestra el informe para pedir ayuda en GitHub si un programa no anda
                                               bien (sin datos personales). Con --abrir, abre el formulario ya llenado
                                               en el navegador (nada se publica hasta que lo envíes); con --enlace,
                                               solo escribe su dirección.
          vitral diagnosticar <app|registro>   Compara lo que pasó con las fallas conocidas y dice qué se sabe de ellas.
          vitral catalogo [--actualizar | --verificar <archivo>]
                                               Muestra qué catálogo de fallas se usa, busca uno nuevo en GitHub
                                               o comprueba la firma de un catálogo.
          vitral version                       Muestra la versión.

        Los comandos también funcionan en inglés (analyze, icon, engines install, engines clean, install, uninstall, programs, add, report, diagnose, catalog). Idioma: VITRAL_LANG=es o en.
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
                         [--arguments "<installer arguments>"]
                                             Install a Windows program and turn it into a Mac app
                                             (in ~/Applications unless another folder is given). --arguments
                                             passes options to the installer, such as Inno Setup's "/VERYSILENT".
          vitral uninstall [--all] <app>     Close the program if it is open and move the app and its logs to the
                                             Trash. Your files in Documents, Downloads… are not touched.
                                             If another app came from the same installer, the files and settings
                                             they share stay; with --all those apps and everything go too.
          vitral programs <app>              The other programs an app's installer brought (a suite).
          vitral add <app> <program>         Make another app for one of them (they share files and settings).
          vitral report [--open|--link] <app>
                                             Show the report to ask for help on GitHub when a program does not work
                                             well (without personal data). With --open, open the form filled in
                                             in the browser (nothing is posted until you send it); with --link,
                                             only print its address.
          vitral diagnose <app|log>          Compare what happened with the known failures and say what is known.
          vitral catalog [--update | --verify <file>]
                                             Show which failure catalog is in use, look for a new one on GitHub,
                                             or check a catalog's signature.
          vitral version                     Show the version.

        Commands also work in Spanish (analizar, icono, motores instalar, motores limpiar, instalar, desinstalar, programas, agregar, informe, diagnosticar, catalogo). Language: VITRAL_LANG=en or es.
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
    case .discImage:
        let label = report.discLabel.map { " «\($0)»" } ?? ""
        return tr("Imagen de CD o DVD\(label) (se instala con el instalador del disco)", "CD or DVD image\(label) (installed with the disc's installer)")
    case .executable:
        if report.executable?.isDLL == true {
            return tr("Biblioteca de Windows (DLL): no se abre sola", "Windows library (DLL): it does not run on its own")
        }
        if ProgramInstaller.looksLikeSetup(report.fileName) {
            return tr("Instalador de tipo desconocido (se abre tal cual)", "Installer of an unknown kind (run as it is)")
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
    case .qtGui: return tr("interfaz Qt (Qt GUI)", "Qt interface (Qt GUI)")
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

func analyze(_ options: [String]) async {
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
    if report.kind == .discImage {
        // Mounted for a moment, hidden, to see the installer on the disc.
        do {
            let contents = try await DiscImage.contents(of: url, in: ProgramInstaller().staging)
            print("  " + tr("En disco: ", "On disc:  ") + contents.setupPath + " · " + describeKind(contents.setup))
            if let info = contents.setup.executable {
                print("  " + tr("Archivo:  ", "File:     ") + describeExecutable(info) + tr(" (el instalador)", " (the installer)"))
                if let product = describeProduct(info.version) { print("  " + tr("Instala:  ", "Installs: ") + product) }
            }
        } catch {
            print("  " + tr("En disco: ", "On disc:  ") + String(describing: error))
        }
        return
    }
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
    var installerArguments: [String] = []
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
        case "--argumentos", "--arguments": installerArguments = ShellLink.splitArguments(value())
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
        if case .installingDotNet(let fraction) = stage {
            let step = Int(fraction * 4)
            if case .installingDotNet(let old) = lastStage.value, Int(old * 4) == step { return }
            lastStage.value = stage
            if fraction == 0 {
                print(tr("    Instalando .NET Framework 4.8 de Microsoft (unos 5 minutos)…",
                         "    Installing Microsoft's .NET Framework 4.8 (about 5 minutes)…"))
            } else {
                print(tr("    .NET Framework… \(Int(fraction * 100)) %", "    .NET Framework… \(Int(fraction * 100)) %"))
            }
            return
        }
        // A step that ends: the installer is still open, nothing new to say.
        if case .runningInstaller(nil) = stage, case .runningInstaller = lastStage.value {
            lastStage.value = stage
            return
        }
        lastStage.value = stage
        switch stage {
        case .checking: print(tr("1/6 Revisando el instalador…", "1/6 Checking the installer…"))
        case .downloadingEngine, .installingDotNet: break
        case .preparingWindows: print(tr("2/6 Preparando el espacio del programa (la primera vez tarda un poco)…", "2/6 Preparing the program's space (the first time takes a while)…"))
        case .runningInstaller(let step?):
            print("    " + step)
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
            installer, options: InstallOptions(destination: destination, name: name, launcher: launcher, replace: replace,
                                      installerArguments: installerArguments),
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
            print(tr("Su instalador no dejó otros programas con acceso directo.", "Its installer left no other programs with a shortcut."))
        }
        for choice in choices { print("\(choice.name)  (\(choice.program))") }
    } catch {
        fail("✗ " + String(describing: error))
    }
}

func report(_ options: [String]) {
    let flags = ["--abrir", "--open", "--enlace", "--link"]
    let open = options.contains { ["--abrir", "--open"].contains($0) }
    let linkOnly = options.contains { ["--enlace", "--link"].contains($0) }
    let rest = options.filter { !flags.contains($0) }
    guard rest.count == 1 else { printUsage(); exit(2) }
    let app = appURL(rest[0])
    guard Wrapper(url: app).isWrapper else {
        fail(tr("✗ \(app.lastPathComponent) no es una app creada por Vitral.", "✗ \(app.lastPathComponent) is not an app made by Vitral."))
    }
    let report = ProblemReporter.app(app)
    if linkOnly { return print(report.issueURL().absoluteString) }
    print(tr("Título: ", "Title: ") + report.title)
    print(tr("Programa: ", "Program: ") + report.program)
    print("Mac: " + report.mac)
    print("Vitral: " + report.vitralVersion)
    print("")
    print(report.text)
    print("")
    let url = report.issueURL()
    if open {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try? process.run()
        process.waitUntilExit()
        print(tr("Abrí el formulario de GitHub en el navegador. Cuenta qué pasó y envíalo (necesitas una cuenta de GitHub).",
                 "Opened GitHub's form in the browser. Say what happened and send it (you need a GitHub account)."))
    } else {
        print(tr("Revisa que no haya nada privado. Para abrir el formulario de GitHub ya llenado: vitral informe --abrir \"\(app.path)\"",
                 "Check there is nothing private. To open GitHub's form filled in: vitral report --open \"\(app.path)\""))
        print(tr("¿Ya está reportado? ", "Already reported? ") + report.searchURL.absoluteString)
    }
}

func diagnose(_ options: [String]) {
    guard options.count == 1 else { printUsage(); exit(2) }
    let path = (options[0] as NSString).expandingTildeInPath
    let diagnoses: [Diagnosis]
    if ["log", "txt"].contains((path as NSString).pathExtension.lowercased()) {
        // A log by itself: any phase it may be.
        let text = LogExcerpt.read(URL(fileURLWithPath: path))
        diagnoses = [FailurePhase.install, .start, .running].flatMap { phase in
            Diagnoser.diagnose(FailureObservation(phase: phase, logs: [text]), catalog: .current)
        }.reduce(into: []) { all, d in if !all.contains(where: { $0.id == d.id }) { all.append(d) } }
    } else {
        let app = appURL(options[0])
        guard Wrapper(url: app).isWrapper else {
            fail(tr("✗ \(app.lastPathComponent) no es una app creada por Vitral.", "✗ \(app.lastPathComponent) is not an app made by Vitral."))
        }
        let inspection = AppInspection(app: app)
        if let run = inspection.lastRun {
            print(tr("Última vez: \(run.seconds) s, código \(run.status), ventana: \(run.sawWindow ? "sí" : "no")",
                     "Last time: \(run.seconds) s, status \(run.status), window: \(run.sawWindow ? "yes" : "no")"))
        }
        for log in inspection.programLogs { print(tr("Registro del programa: ", "Program log: ") + log.lastPathComponent) }
        diagnoses = inspection.diagnoses()
        if let manifest = inspection.manifest, let prefix = inspection.prefix {
            let repairs = RepairPlanner.plan(diagnoses, settings: manifest.settings, prefix: prefix)
            if !repairs.isEmpty {
                print(tr("Si no abre, el lanzador probará: ", "If it does not open, the launcher will try: ")
                      + repairs.map { "\($0.description) [\($0.key)]" }.joined(separator: "; "))
            }
        }
    }
    if diagnoses.isEmpty {
        print(tr("No reconozco ninguna falla conocida.", "No known failure recognized."))
    }
    for diagnosis in diagnoses {
        print("")
        print("• \(diagnosis.title) [\(diagnosis.id), \(diagnosis.kind.rawValue)]")
        print("  " + diagnosis.explanation)
        if let evidence = diagnosis.evidence { print(tr("  Visto: ", "  Seen: ") + evidence) }
        if !diagnosis.fixesText.isEmpty { print(tr("  Se puede probar: ", "  Can try: ") + diagnosis.fixesText.joined(separator: "; ")) }
    }
}

func catalog(_ options: [String]) async {
    let store = CatalogStore()
    switch options.first {
    case "--verificar", "--verify":
        guard options.count == 2 else { printUsage(); exit(2) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: (options[1] as NSString).expandingTildeInPath))
            let catalog = try JSONDecoder().decode(SignedCatalog.self, from: data).verified(publicKey: CatalogStore.publicKey)
            print(tr("✓ Firma válida. Revisión \(catalog.revision), \(catalog.entries.count) entradas.",
                     "✓ Valid signature. Revision \(catalog.revision), \(catalog.entries.count) entries."))
        } catch {
            fail("✗ \(error)")
        }
        return
    case "--actualizar", "--update":
        do {
            let best = try await store.refresh()
            print(tr("Catálogo en uso: revisión \(best.revision).", "Catalog in use: revision \(best.revision)."))
        } catch {
            fail(tr("✗ No se pudo bajar el catálogo: \(error)", "✗ Could not download the catalog: \(error)"))
        }
    case nil:
        break
    default:
        printUsage(); exit(2)
    }
    let builtIn = FailureCatalog.builtIn
    print(tr("Incluido en Vitral: revisión \(builtIn.revision), \(builtIn.entries.count) entradas.",
             "Built into Vitral: revision \(builtIn.revision), \(builtIn.entries.count) entries."))
    do {
        if let downloaded = try store.downloaded() {
            print(tr("Descargado: revisión \(downloaded.revision), \(downloaded.entries.count) entradas (firma válida).",
                     "Downloaded: revision \(downloaded.revision), \(downloaded.entries.count) entries (valid signature)."))
        } else {
            print(tr("Descargado: ninguno todavía.", "Downloaded: none yet."))
        }
    } catch {
        print(tr("Descargado: no sirve (\(error)).", "Downloaded: unusable (\(error))."))
    }
    print(tr("En uso: revisión \(store.best().revision).", "In use: revision \(store.best().revision)."))
    if let last = store.lastCheck { print(tr("Última búsqueda: ", "Last check: ") + last.formatted()) }
    print(CatalogStore.automaticChecks
          ? tr("Se busca solo (con «Buscar actualizaciones automáticamente»).", "Looked for automatically (with “Check for updates automatically”).")
          : tr("No se busca solo: «Buscar actualizaciones automáticamente» está desactivado.", "Not looked for automatically: “Check for updates automatically” is off."))
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
        print(tr("✓ \(choice.name): \(added.path) (comparte archivos y ajustes con \(app.deletingPathExtension().lastPathComponent))",
                 "✓ \(choice.name): \(added.path) (shares files and settings with \(app.deletingPathExtension().lastPathComponent))"))
    } catch {
        fail("✗ " + String(describing: error))
    }
}

func uninstall(_ options: [String]) async {
    let together = options.contains { ["--todas", "--all"].contains($0) }
    let paths = options.filter { !["--todas", "--all"].contains($0) }
    guard paths.count == 1 else {
        printUsage()
        exit(2)
    }
    let app = appURL(paths[0])
    do {
        let companions = Uninstaller.companions(of: app)
        let trashed = together ? try await Uninstaller().uninstallWithCompanions(app) : try await Uninstaller().uninstall(app)
        print(tr("✓ A la Papelera (se puede recuperar desde ahí):", "✓ Moved to the Trash (you can put it back from there):"))
        for item in trashed { print("  " + item.path) }
        if !together, !companions.isEmpty {
            let names = companions.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")
            print(tr("Sus archivos y ajustes se quedan: los usa \(names). Para quitar todo: vitral desinstalar --todas <app>",
                     "Its files and settings stay: \(names) uses them. To remove everything: vitral uninstall --all <app>"))
        }
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
    await analyze(Array(arguments.dropFirst()))
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
case "informe", "report":
    report(Array(arguments.dropFirst()))
case "diagnosticar", "diagnose":
    diagnose(Array(arguments.dropFirst()))
case "catalogo", "catálogo", "catalog":
    await catalog(Array(arguments.dropFirst()))
case "version", "versión", "--version", "-v":
    print("Vitral \(Vitral.version)")
case "ayuda", "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data((tr("Comando desconocido: ", "Unknown command: ") + command + "\n\n").utf8))
    printUsage()
    exit(2)
}
