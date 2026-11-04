import SwiftUI
import UniformTypeIdentifiers
import VitralKit

/// The main window: your Windows apps, and a place to drop a new installer.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var choosingFile = false

    var body: some View {
        @Bindable var model = model

        ZStack {
            StainedGlassBackground().ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                header
                DropZone(isTargeted: isTargeted) { choosingFile = true }
                if model.needsSetup { setupBanner }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, 18)
            .padding(.bottom, 30)
            .frame(maxWidth: 980)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: Self.installerTypes) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { choosingFile = true } label: {
                    Label("Abrir instalador…", systemImage: "plus")
                }
                .help("Abrir un instalador de Windows (.exe, .msi o .zip)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showSetup = true } label: {
                    Label("Preparar la Mac", systemImage: model.needsSetup ? "exclamationmark.circle" : "checkmark.circle")
                }
                .help("Ver qué necesita tu Mac para abrir programas de Windows")
            }
        }
        .sheet(isPresented: $model.showSetup) {
            SetupView()
        }
        .sheet(item: $model.dropped) { file in
            AnalysisView(file: file)
        }
        .alert("No se puede abrir", isPresented: Binding(get: { model.dropError != nil }, set: { if !$0 { model.dropError = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.dropError ?? "")
        }
    }

    static let installerTypes: [UTType] = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) } + [.zip]

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tus apps de Windows")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Cada programa queda como una app de Mac, con su ícono, lista para abrir con doble clic.")
                .foregroundStyle(.secondary)
        }
    }

    private var setupBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Palette.panes[2])
            VStack(alignment: .leading, spacing: 2) {
                Text("Falta preparar tu Mac").font(.headline)
                Text("Vitral necesita instalar algunas cosas antes de abrir programas de Windows.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preparar") { model.showSetup = true }
                .prominentGlassButton()
        }
        .padding(18)
        .vitralGlass(cornerRadius: 18)
    }
}

/// The big target for installers. Glows when something is dragged over it.
struct DropZone: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Palette.accent : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            Text("Arrastra aquí un instalador de Windows")
                .font(.title3.weight(.medium))
            Text("Vitral lo revisa antes de instalar nada: qué es, con qué está hecho y qué necesita.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Elegir archivo…", action: choose)
                .glassButton()
                .controlSize(.large)
                .padding(.top, 4)
            Text(".exe · .msi · .zip")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 44)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
        .vitralGlass(cornerRadius: 26, tint: isTargeted ? Palette.accent : nil)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(isTargeted ? Palette.accent : .secondary.opacity(0.35))
                .padding(10)
        }
        .scaleEffect(isTargeted ? 1.01 : 1)
        .animation(.spring(duration: 0.3), value: isTargeted)
    }
}
