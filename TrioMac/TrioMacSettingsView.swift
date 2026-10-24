#if targetEnvironment(macCatalyst)
    import ServiceManagement
    import SwiftUI

    struct TrioMacSettingsView: View {
        @State private var status: SMAppService.Status = .notRegistered
        @State private var message: String?

        private var service: SMAppService {
            SMAppService.loginItem(identifier: (Bundle.main.bundleIdentifier ?? "") + ".menubar")
        }

        var body: some View {
            Form {
                Section("Menüleiste") {
                    Text("Glukose, IOB und COB aus dieser Trio-Instanz direkt in der Menüleiste anzeigen.")
                    if status == .enabled {
                        Button("Menüleisten-Einstellungen öffnen") {
                            UIApplication.shared.open(URL(string: "trio-menubar://settings")!) { opened in
                                if !opened { message = "Die Menüleisten-App konnte nicht geöffnet werden." }
                            }
                        }
                        Button("Menüleisten-App deaktivieren") {
                            do {
                                try service.unregister()
                                refresh()
                            } catch { message = error.localizedDescription }
                        }
                    } else {
                        Button("Menüleisten-App aktivieren") {
                            do {
                                try service.register()
                                refresh()
                            } catch { message = error.localizedDescription }
                        }
                    }
                    if status == .requiresApproval {
                        Text("macOS benötigt deine Freigabe unter Anmeldeobjekte.")
                        Button("Systemeinstellungen öffnen") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section("Widgets") {
                    Text("Füge „Trio Status“ über die macOS-Widgetauswahl hinzu. Die Anzeige verwendet lokale Messwerte und zeigt deren Alter.")
                }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Mac-Anzeige")
            .onAppear(perform: refresh)
        }

        private func refresh() {
            status = service.status
            message = nil
        }
    }
#endif
