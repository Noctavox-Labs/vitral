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
          vitral version                       Muestra la versión.

        Los comandos también funcionan en inglés (analyze). Idioma: VITRAL_LANG=es o en.
        """,
        """
        Vitral \(Vitral.version): Windows programs on your Mac.

        Usage:
          vitral analyze [--json] <file>   Inspect a Windows installer or program without running it.
          vitral version                   Show the version.

        Commands also work in Spanish (analizar). Language: VITRAL_LANG=en or es.
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

func analyze(_ options: [String]) {
    let json = options.contains("--json")
    let paths = options.filter { $0 != "--json" }
    guard paths.count == 1 else {
        printUsage()
        exit(2)
    }

    let url = URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath)
    let report: InstallerReport
    do {
        report = try InstallerAnalyzer.analyze(fileAt: url)
    } catch InstallerAnalyzerError.notFound {
        fail(tr("No encontré el archivo: \(paths[0])", "File not found: \(paths[0])"))
    } catch InstallerAnalyzerError.notAFile {
        fail(tr("Es una carpeta, no un archivo: \(paths[0])", "That is a folder, not a file: \(paths[0])"))
    } catch {
        fail(tr("No pude leer el archivo: \(error.localizedDescription)", "Could not read the file: \(error.localizedDescription)"))
    }

    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(report)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return
    }

    print("\(report.fileName)  (\(formatSize(report.sizeBytes)))")
    print("  " + tr("Tipo:     ", "Type:     ") + describeKind(report))
    if let info = report.executable {
        let label = report.kind == .executable ? tr("Programa: ", "Program:  ") : tr("Archivo:  ", "File:     ")
        print("  " + label + describeExecutable(info))
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
case "version", "versión", "--version", "-v":
    print("Vitral \(Vitral.version)")
case "ayuda", "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data((tr("Comando desconocido: ", "Unknown command: ") + command + "\n\n").utf8))
    printUsage()
    exit(2)
}
