import SwiftUI
import VitralKit

/// The report to ask for help on GitHub, shown before anything leaves the Mac. The person can
/// change it; then GitHub's form opens filled in, where they decide whether to send it.
struct ReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Gathers the report (reads logs, may hash the installer).
    let prepare: @MainActor () async -> ProblemReport
    @State private var report: ProblemReport?
    @State private var summary = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Informar un problema")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            if let report {
                form(report)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Palette.progress)
                    Text("Preparando el informe…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                HStack {
                    Spacer()
                    Button("Cancelar") { dismiss() }
                        .glassButton()
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 660)
        .task {
            let prepared = await prepare()
            summary = prepared.summary
            text = prepared.text
            report = prepared
        }
    }

    @ViewBuilder
    private func form(_ report: ProblemReport) -> some View {
        Text(report.title + (report.kind == .other ? "…" : ""))
            .font(.headline)
            .textSelection(.enabled)

        VStack(alignment: .leading, spacing: 6) {
            Text("¿Qué pasó?").foregroundStyle(.secondary)
            editor($summary, height: 70, monospaced: false)
                .overlay(alignment: .topLeading) {
                    if summary.isEmpty {
                        Text("Cuenta qué esperabas y qué viste.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Informe de Vitral").foregroundStyle(.secondary)
            editor($text, height: 230, monospaced: true)
            Text("\(report.mac) · Vitral \(report.vitralVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        Text("No lleva tu nombre ni tus carpetas; igual revísalo y borra o cambia lo que quieras. Se abrirá el formulario de GitHub ya lleno en tu navegador: nada se publica hasta que lo envíes, y necesitas una cuenta de GitHub. Una captura de la ventana del programa ayuda: arrástrala al formulario.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Button("¿Ya está reportado?") { openURL(report.searchURL) }
                .glassButton()
                .help("Buscar en GitHub informes de este programa")
            if let log = report.logFile, FileManager.default.fileExists(atPath: log.path) {
                Button("Mostrar el registro") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    .glassButton()
                    .help("El registro completo, por si quieres adjuntarlo")
            }
            Spacer()
            Button("Cancelar") { dismiss() }
                .glassButton()
                .keyboardShortcut(.cancelAction)
            Button("Abrir en GitHub") {
                openURL(report.issueURL(text: text, summary: summary))
                dismiss()
            }
            .prominentGlassButton()
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    private func editor(_ value: Binding<String>, height: CGFloat, monospaced: Bool) -> some View {
        TextEditor(text: value)
            .font(monospaced ? .system(size: 11, design: .monospaced) : .body)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: height)
            .vitralGlass(cornerRadius: 12)
    }
}
