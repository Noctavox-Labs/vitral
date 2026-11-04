import SwiftUI
import VitralKit

/// What Vitral found in a dropped installer, before installing anything.
struct AnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    let file: AppModel.DroppedFile

    private var report: InstallerReport { file.report }
    private var version: VersionInfo? { report.executable?.version }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text(productName)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    if let company = version?.companyName {
                        Text(company).foregroundStyle(.secondary)
                    }
                    if let number = version?.productVersion {
                        Text("Versión \(number)").font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                fact("Archivo", report.fileName + " · " + ByteCountFormatter.string(fromByteCount: report.sizeBytes, countStyle: .file), "doc")
                Divider().padding(.leading, 44)
                fact("Tipo", kindText, "shippingbox")
                if let executable = report.executable {
                    Divider().padding(.leading, 44)
                    fact("Programa", executableText(executable), "cpu")
                }
                if !report.companionFiles.isEmpty {
                    Divider().padding(.leading, 44)
                    fact("Necesita", report.companionFiles.joined(separator: ", "), "link")
                }
            }
            .padding(.vertical, 4)
            .vitralGlass(cornerRadius: 16)

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("La instalación automática llega en la próxima versión.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
                Button("Instalar") {}
                    .prominentGlassButton()
                    .disabled(true)
            }
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 560)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = file.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .padding(10)
                .vitralGlass(cornerRadius: 20)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 40, weight: .light))
                .frame(width: 92, height: 92)
                .vitralGlass(cornerRadius: 20)
        }
    }

    private var productName: String {
        version?.productName ?? version?.fileDescription ?? report.fileName
    }

    private func fact(_ label: LocalizedStringKey, _ value: String, _ symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var kindText: String {
        let number = report.kindVersion.map { " " + $0 } ?? ""
        switch report.kind {
        case .innoSetup: return String(localized: "Instalador Inno Setup\(number)")
        case .nsis: return String(localized: "Instalador NSIS\(number)")
        case .msi: return String(localized: "Paquete de Windows Installer")
        case .wixBurn: return String(localized: "Instalador WiX (varios paquetes)")
        case .installShield: return String(localized: "Instalador InstallShield")
        case .sevenZipSFX: return String(localized: "Archivo 7-Zip autoextraíble")
        case .zip: return String(localized: "Archivo ZIP")
        case .executable: return String(localized: "Programa (no es un instalador)")
        case .unknown: return String(localized: "Desconocido")
        }
    }

    private func executableText(_ info: ExecutableInfo) -> String {
        switch info.format {
        case .dos: return String(localized: "MS-DOS")
        case .windows16: return String(localized: "Windows de 16 bits")
        case .pe32, .pe32Plus:
            return info.subsystem == .console
                ? String(localized: "Windows de \(info.bits) bits, de consola")
                : String(localized: "Windows de \(info.bits) bits, con interfaz gráfica")
        }
    }

    private var warning: String? {
        if report.executable?.format == .windows16 {
            return String(localized: "Los programas de Windows de 16 bits no funcionan con Wine en Mac.")
        }
        if report.executable?.format == .dos {
            return String(localized: "Es un programa de MS-DOS: Vitral no lo puede abrir.")
        }
        if report.executable?.isDLL == true {
            return String(localized: "Es una biblioteca (DLL), no un programa: no se abre sola.")
        }
        if report.kind == .unknown {
            return String(localized: "No parece un instalador ni un programa de Windows.")
        }
        return nil
    }
}
