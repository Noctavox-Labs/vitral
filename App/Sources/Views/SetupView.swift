import SwiftUI
import VitralKit

/// First-run assistant: checks everything a fresh Mac needs and installs what is missing.
/// Also shown from Settings → System.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// In Settings it is a plain list, without the welcome header and the buttons.
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !embedded { header }

            VStack(spacing: 0) {
                ForEach(Array(model.requirements.enumerated()), id: \.element.id) { index, requirement in
                    if index > 0 { Divider().padding(.leading, 58) }
                    RequirementRow(requirement: requirement)
                }
            }
            .padding(.vertical, 6)
            .vitralGlass(cornerRadius: 18)

            if !embedded { footer }
        }
        .padding(embedded ? 0 : 30)
        .frame(width: embedded ? nil : 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppMark(size: 54)
            VStack(alignment: .leading, spacing: 6) {
                Text("Preparemos tu Mac")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Vitral revisa lo que hace falta para abrir programas de Windows y se encarga de instalarlo. No necesitas la Terminal.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.needsSetup {
                Text("Puedes terminarlo después en Ajustes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("Todo listo", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            }
            Spacer()
            if model.needsSetup {
                Button("Más tarde") { dismiss() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
            }
            Button(model.needsSetup ? "Instalar todo" : "Empezar") {
                if model.needsSetup {
                    Task { await installEverything() }
                } else {
                    dismiss()
                }
            }
            .prominentGlassButton()
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || hasBlocking)
        }
        .controlSize(.large)
    }

    private var isBusy: Bool {
        if case .working = model.engineTask { return true }
        if case .working = model.rosettaTask { return true }
        return false
    }

    private var hasBlocking: Bool { model.requirements.contains { $0.status == .blocking } }

    private func installEverything() async {
        if !model.mac.hasRosetta { await model.installRosetta() }
        if !model.engineInstalled { await model.installEngine() }
    }
}

/// One line of the checklist: what it is, what was found, and the action if one is needed.
struct RequirementRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let requirement: Requirement

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.symbol(tint, dark: colorScheme == .dark))
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    Text(requirement.detail).foregroundStyle(.secondary)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .working(let progress, let message) = task {
                    VStack(alignment: .leading, spacing: 3) {
                        if let progress {
                            ProgressView(value: progress).tint(Palette.progress)
                            Text("\(message) · \(Int(progress * 100)) %")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
                if case .failed(let message) = task {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var trailing: some View {
        switch requirement.status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .blocking:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title3)
        case .fixable:
            if case .working = task {
                EmptyView()
            } else {
                Button(actionTitle) { Task { await act() } }
                    .glassButton()
            }
        }
    }

    private var task: AppModel.TaskState {
        switch requirement.kind {
        case .engine: model.engineTask
        case .rosetta: model.rosettaTask
        default: .idle
        }
    }

    private func act() async {
        switch requirement.kind {
        case .engine: await model.installEngine()
        case .rosetta: await model.installRosetta()
        default: break
        }
    }

    private var actionTitle: LocalizedStringKey {
        switch requirement.kind {
        case .engine: "Descargar \(ByteCountFormatter.string(fromByteCount: model.engineDownloadBytes, countStyle: .file))"
        default: "Instalar"
        }
    }

    private var symbol: String {
        switch requirement.kind {
        case .appleSilicon: "cpu"
        case .macOS: "macwindow"
        case .memory: "memorychip"
        case .rosetta: "arrow.triangle.2.circlepath"
        case .diskSpace: "internaldrive"
        case .engine: "shippingbox"
        }
    }

    private var tint: Color {
        switch requirement.kind {
        case .appleSilicon: Palette.panes[0]
        case .macOS: Palette.panes[4]
        case .memory: Palette.panes[5]
        case .rosetta: Palette.panes[2]
        case .diskSpace: Palette.panes[1]
        case .engine: Palette.panes[3]
        }
    }

    private var title: LocalizedStringKey {
        switch requirement.kind {
        case .appleSilicon: "Chip"
        case .macOS: "Sistema"
        case .memory: "Memoria"
        case .rosetta: "Rosetta"
        case .diskSpace: "Espacio"
        case .engine: "Motor de Windows"
        }
    }

    private var explanation: LocalizedStringKey {
        switch (requirement.kind, requirement.status) {
        case (.appleSilicon, .ok): "Mac con chip de Apple."
        case (.appleSilicon, _): "Vitral está hecho para Mac con chip de Apple; en Intel puede no funcionar."
        case (.macOS, .blocking): "Vitral necesita macOS 14 o más nuevo."
        case (.macOS, .warning): "Apple anunció que Rosetta deja de ser de uso general después de macOS 27; algunos programas podrían no abrir."
        case (.macOS, _): "Compatible."
        case (.memory, .warning): "Con poca memoria, los programas grandes pueden ir lentos."
        case (.memory, _): "Suficiente para la mayoría de los programas."
        case (.rosetta, .ok): "Traduce el código de los programas de Windows para tu chip."
        case (.rosetta, _): "Traduce el código de los programas de Windows para tu chip. macOS te pedirá tu contraseña."
        case (.diskSpace, .blocking): "Hacen falta al menos 3 GB libres."
        case (.diskSpace, _): "Hay lugar para el motor y tus programas."
        case (.engine, .ok): "Wine de CrossOver (compilación de Sikarugir), comprobado con SHA-256."
        case (.engine, _): "Wine de CrossOver, compilado por el proyecto Sikarugir. Se descarga de GitHub y se comprueba con SHA-256 antes de usarlo."
        }
    }
}

/// Vitral's mark: a small stained-glass window.
struct AppMark: View {
    var size: CGFloat = 48

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
