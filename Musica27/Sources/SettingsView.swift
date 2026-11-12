import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sourceMode") private var sourceMode = "auto"
    @AppStorage("autoRadio") private var autoRadio = true
    @AppStorage("customPiped") private var customPiped = ""
    @AppStorage("customInvidious") private var customInvidious = ""
    @ObservedObject private var log = AppLog.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Seguir con canciones parecidas", isOn: $autoRadio)
                } header: {
                    Text("Reproducción")
                } footer: {
                    Text("Cuando se termina la lista, sigue con una radio armada a partir de la última canción.")
                }

                Section {
                    Picker("Fuente", selection: $sourceMode) {
                        Text("Automática").tag("auto")
                        Text("Solo YouTube directo").tag("direct")
                        Text("Solo Piped e Invidious").tag("community")
                    }
                } header: {
                    Text("Conexión")
                } footer: {
                    Text("Automática prueba YouTube directo y, si falla, instancias públicas de Piped e Invidious.")
                }

                Section {
                    TextField("Piped: https://pipedapi.ejemplo.com", text: $customPiped)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Invidious: https://inv.ejemplo.com", text: $customInvidious)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Tus instancias (opcional)")
                } footer: {
                    Text("Se prueban antes que las que vienen incluidas.")
                }

                Section {
                    Button("Copiar registro") {
                        UIPasteboard.general.string = log.lines.joined(separator: "\n")
                    }
                    Button("Borrar registro", role: .destructive) {
                        log.clear()
                    }
                    Text(logText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Color.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Registro")
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    private var logText: String {
        if log.lines.isEmpty { return "Todavía no hay eventos." }
        return log.lines.suffix(80).joined(separator: "\n")
    }
}
