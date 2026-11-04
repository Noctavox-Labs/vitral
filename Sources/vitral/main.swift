import Foundation
import VitralKit

// `vitral` command-line tool. Every command has a Spanish and an English name.

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
          vitral version                       Muestra la versión.

        Los comandos también funcionan en inglés (analyze, icon). Idioma: VITRAL_LANG=es o en.
        """,
        """
        Vitral \(Vitral.version): Windows programs on your Mac.

        Usage:
          vitral analyze [--json] <file>     Inspect a Windows installer or program without running it.
          vitral analyze [--json] <folder>   Inspect an installed program: which file to open and what it is built with.
          vitral icon <program.exe> <output.icns|.ico>
                                             Extract the icon of a Windows program.
          vitral version                     Show the version.

        Commands also work in Spanish (analizar, icono). Language: VITRAL_LANG=en or es.
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
    case .nsis: return tr("Instalador NSIS\(version)", "NSIS installer\(version)")
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
        case (false, .gui?): kind = tr("con ventanas", "graphical")
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
        print("  " + label + describeExecutable(info))
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
case "version", "versión", "--version", "-v":
    print("Vitral \(Vitral.version)")
case "ayuda", "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data((tr("Comando desconocido: ", "Unknown command: ") + command + "\n\n").utf8))
    printUsage()
    exit(2)
}
