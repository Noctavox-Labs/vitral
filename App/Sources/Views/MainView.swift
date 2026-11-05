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

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if model.needsSetup { setupBanner }
                    if !model.library.isEmpty { LibraryGrid() }
                    DropZone(isTargeted: isTargeted, compact: !model.library.isEmpty) { choosingFile = true }
                }
                .padding(.horizontal, 36)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear { model.refreshLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLibrary()
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
        .alert("No se pudo desinstalar", isPresented: Binding(get: { model.uninstallError != nil }, set: { if !$0 { model.uninstallError = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.uninstallError ?? "")
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
    var compact = false
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
        .padding(.vertical, compact ? 26 : 44)
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

/// The apps Vitral has made, as glass cards.
struct LibraryGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], alignment: .leading, spacing: 16) {
            ForEach(model.library) { app in
                LibraryCard(app: app)
            }
        }
        .glassGroup(spacing: 16)
    }
}

struct LibraryCard: View {
    @Environment(AppModel.self) private var model
    let app: AppModel.LibraryApp
    @State private var hovering = false
    @State private var confirmingUninstall = false

    var body: some View {
        Button { model.openApp(app.url) } label: {
            VStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                if let company = app.manifest.product?.companyName {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 170)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .vitralGlass(cornerRadius: 22, tint: hovering ? Palette.accent : nil)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .help("Abrir \(app.name)")
        .contextMenu {
            Button("Abrir") { model.openApp(app.url) }
            Button("Mostrar en Finder") { model.showInFinder(app.url) }
            Divider()
            Button("Desinstalar…", role: .destructive) { confirmingUninstall = true }
        }
        .confirmationDialog("¿Desinstalar \(app.name)?", isPresented: $confirmingUninstall) {
            Button("Mover a la Papelera", role: .destructive) {
                Task { await model.uninstall(app) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Si está abierto, se cierra. La app (con el programa y su configuración) y sus registros van a la Papelera, desde donde se pueden recuperar. Tus archivos en Documentos, Descargas, Música, Imágenes y Películas no se tocan.")
        }
    }
}
