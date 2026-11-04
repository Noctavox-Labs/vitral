import SwiftUI
import VitralKit

/// What Vitral found in a dropped installer, and the installation itself.
struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: AppModel.DroppedFile

    private var report: InstallerReport { file.report }
    private var version: VersionInfo? { report.executable?.version }
    private var refusal: String? { ProgramInstaller.refusal(report) }

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

            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(30)
        .frame(width: 560)
        .interactiveDismissDisabled(model.isInstalling)
    }

    // MARK: Footer: install, progress, result

    @ViewBuilder
    private var footer: some View {
        switch model.installState {
        case .idle:
            HStack {
                Text(model.mac.hasRosetta ? "Quedará como una app en Aplicaciones, en tu carpeta personal." : "Antes hace falta instalar Rosetta.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
                Button("Instalar") { Task { await model.install(file) } }
                    .prominentGlassButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(refusal != nil || !model.mac.hasRosetta)
            }
            .controlSize(.large)

        case .working(let stage):
            VStack(alignment: .leading, spacing: 8) {
                if case .downloadingEngine(let fraction) = stage {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(stageText(stage))
                    .font(.callout.weight(.medium))
                if stage == .runningInstaller {
                    Text("Si al terminar abre el programa, Vitral lo cierra y sigue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .vitralGlass(cornerRadius: 16, tint: Palette.accent)

        case .done(let app):
            HStack {
                Label("\(app.deletingPathExtension().lastPathComponent) está lista", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Mostrar en Finder") { model.showInFinder(app) }
                    .glassButton()
                Button("Abrir") {
                    model.openApp(app)
                    dismiss()
                }
                .prominentGlassButton()
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cerrar") { dismiss() }
                        .glassButton()
                        .keyboardShortcut(.cancelAction)
                    Button("Intentar otra vez") { Task { await model.install(file) } }
                        .prominentGlassButton()
                }
                .controlSize(.large)
            }
        }
    }

    private func stageText(_ stage: InstallStage) -> String {
        switch stage {
        case .checking: String(localized: "Revisando el instalador…")
        case .downloadingEngine(let fraction): String(localized: "Descargando el motor de Windows… \(Int(fraction * 100)) %")
        case .preparingWindows: String(localized: "Preparando Windows…")
        case .runningInstaller: String(localized: "Sigue los pasos del instalador en su ventana.")
        case .copyingProgram: String(localized: "Copiando el programa…")
        case .findingProgram: String(localized: "Buscando el programa instalado…")
        case .applyingSettings: String(localized: "Aplicando los ajustes recomendados…")
        case .buildingApp: String(localized: "Creando la app…")
        }
    }

    // MARK: Facts

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
}
