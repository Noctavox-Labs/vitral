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
        .alert("No se pudo cerrar", isPresented: Binding(get: { model.forceQuitError != nil }, set: { if !$0 { model.forceQuitError = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.forceQuitError ?? "")
        }
        .alert("No se pudo agregar el programa", isPresented: Binding(get: { model.addProgramError != nil }, set: { if !$0 { model.addProgramError = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.addProgramError ?? "")
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
            ForEach(model.pendingApps) { pending in
                PendingCard(app: pending)
            }
        }
        .glassGroup(spacing: 16)
        // Which apps are open, for "Force Quit" in their menu.
        .task {
            while !Task.isCancelled {
                await model.refreshOpenApps()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// A card for an app Vitral is still making: it breathes and says so until the app is ready.
struct PendingCard: View {
    let app: AppModel.PendingApp

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .phaseAnimator([false, true]) { icon, dim in
                    icon.opacity(dim ? 0.35 : 0.8).scaleEffect(dim ? 0.92 : 1)
                } animation: { _ in .easeInOut(duration: 0.8) }
            Text(app.name)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(Palette.progress)
                Text("Agregando…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 170)
        .vitralGlass(cornerRadius: 22)
        .help("Vitral está creando la app de \(app.name)")
    }
}

struct LibraryCard: View {
    @Environment(AppModel.self) private var model
    let app: AppModel.LibraryApp
    @State private var hovering = false
    @State private var confirmingUninstall = false
    @State private var confirmingForceQuit = false
    @State private var reporting = false

    var body: some View {
        let opening = model.opening.contains(app.url)
        let quitting = model.quitting.contains(app.url)
        Button { model.openApp(app.url) } label: {
            VStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    // Breathes while the program starts.
                    .phaseAnimator(opening ? [false, true] : [false]) { icon, dim in
                        icon.opacity(dim ? 0.45 : 1).scaleEffect(dim ? 0.94 : 1)
                    } animation: { _ in .easeInOut(duration: 0.8) }
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                if quitting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(Palette.progress)
                        Text("Cerrando…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if opening {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(Palette.progress)
                        Text("Abriendo…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let company = app.manifest.product?.companyName {
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
            if model.isOpen(app) {
                Button("Forzar cierre…") { confirmingForceQuit = true }
                    .disabled(quitting)
            }
            Button("Mostrar en Finder") { model.showInFinder(app.url) }
            Button("Informar un problema…") { reporting = true }
            if !app.others.isEmpty {
                Divider()
                Menu("Agregar otro programa del mismo instalador") {
                    ForEach(app.others, id: \.self) { choice in
                        Button(choice.name) { Task { await model.addProgram(choice, to: app) } }
                            .disabled(model.pendingApps.contains { $0.name == choice.name })
                    }
                }
            }
            Divider()
            Button("Desinstalar…", role: .destructive) { confirmingUninstall = true }
        }
        .sheet(isPresented: $reporting) {
            ReportView { await model.report(for: app) }
        }
        .confirmationDialog("¿Forzar el cierre de \(app.name)?", isPresented: $confirmingForceQuit) {
            Button("Forzar cierre", role: .destructive) {
                Task { await model.forceQuit(app) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let companions = model.companions(of: app)
            if companions.isEmpty {
                Text("Úsalo si se congeló o no se cierra. Se cierra de inmediato y lo que no hayas guardado se pierde.")
            } else if companions.count == 1 {
                Text("Úsalo si se congeló o no se cierra. Se cierra de inmediato y lo que no hayas guardado se pierde. Si \(companions[0]) está abierto, también se cierra: es del mismo instalador.")
            } else {
                Text("Úsalo si se congeló o no se cierra. Se cierra de inmediato y lo que no hayas guardado se pierde. Si \(companions.formatted(.list(type: .and))) están abiertos, también se cierran: son del mismo instalador.")
            }
        }
        .confirmationDialog("¿Desinstalar \(app.name)?", isPresented: $confirmingUninstall) {
            let companions = model.companions(of: app)
            if companions.isEmpty {
                Button("Mover a la Papelera", role: .destructive) {
                    Task { await model.uninstall(app) }
                }
            } else {
                Button("Desinstalar también \(companions.formatted(.list(type: .and)))", role: .destructive) {
                    Task { await model.uninstall(app, withCompanions: true) }
                }
                Button("Solo \(app.name)") {
                    Task { await model.uninstall(app) }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let companions = model.companions(of: app)
            if companions.isEmpty {
                Text("Si está abierto, se cierra. La app (con el programa y su configuración) y sus registros van a la Papelera, desde donde se pueden recuperar. Tus archivos en Documentos, Descargas, Música, Imágenes y Películas no se tocan.")
            } else {
                Text("Vino con \(companions.formatted(.list(type: .and))), del mismo instalador: comparten archivos y ajustes. Si desinstalas también las otras, se borra todo; si solo esta, los archivos y ajustes se quedan para las otras. Todo va a la Papelera, desde donde se puede recuperar. Tus archivos en Documentos, Descargas, Música, Imágenes y Películas no se tocan.")
            }
        }
    }
}
