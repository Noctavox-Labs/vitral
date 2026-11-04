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
                Link("Código fuente en GitHub", destination: URL(string: "https://github.com/noctavoxfilms/vitral")!)
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
            SetupView(embedded: true)
                .padding(20)
        }
        .frame(height: 520)
        .background(StainedGlassBackground())
        .onAppear { model.refresh() }
    }
}
