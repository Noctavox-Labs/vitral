import SwiftUI
import VitralKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SystemSettings()
                .tabItem { Label("Sistema", systemImage: "cpu") }
        }
        .frame(width: 600)
    }
}

/// Updates and version.
struct GeneralSettings: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater

        Form {
            Section {
                Toggle("Buscar actualizaciones automáticamente", isOn: $updater.checksAutomatically)
                    .disabled(!updater.isAvailable)
                Toggle("Instalar las actualizaciones automáticamente", isOn: $updater.installsAutomatically)
                    .disabled(!updater.isAvailable || !updater.checksAutomatically)
                HStack {
                    Button("Buscar ahora") { updater.checkNow() }
                        .disabled(!updater.isAvailable)
                    Spacer()
                    if let last = updater.lastCheck {
                        Text("Última revisión: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Actualizaciones")
            } footer: {
                Text(updater.isAvailable
                     ? "Vitral se actualiza solo, dentro de la app: baja la versión nueva, comprueba su firma y la instala al reiniciar."
                     : "Esta copia se compiló desde el código fuente, así que no se actualiza sola. Las versiones publicadas sí.")
                    .foregroundStyle(.secondary)
            }

            Section("Acerca de") {
                LabeledContent("Versión", value: updater.version)
                LabeledContent("Licencia", value: "GPL-3.0")
                Link("Código fuente en GitHub", destination: URL(string: "https://github.com/noctavox-labs/vitral")!)
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}

/// The same checklist as the setup assistant.
struct SystemSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SetupView(embedded: true)
                UnusedEngines()
            }
            .padding(20)
        }
        .frame(height: 520)
        .background(StainedGlassBackground())
        .onAppear { model.refresh() }
    }
}

/// Engines that no installed app uses any more (for example after uninstalling the last app
/// that needed an older one). They can be downloaded again if a program needs them.
struct UnusedEngines: View {
    @Environment(AppModel.self) private var model
    @State private var bytes: Int64 = 0
    @State private var freed: Int64?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Motores sin usar").font(.headline)
                Group {
                    if let freed {
                        Text("Liberados \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)).")
                    } else if bytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) que ninguna app usa. Se vuelven a bajar si un programa los necesita.")
                    } else {
                        Text("Todos los motores instalados están en uso.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if bytes > 0 && freed == nil {
                Button("Borrar") {
                    freed = model.removeUnusedEngines()
                    bytes = 0
                }
                .glassButton()
            }
        }
        .padding(16)
        .vitralGlass(cornerRadius: 16)
        .onAppear {
            freed = nil
            bytes = model.unusedEngineBytes
        }
    }
}
