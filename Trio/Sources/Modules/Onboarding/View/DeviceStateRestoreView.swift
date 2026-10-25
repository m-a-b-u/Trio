import SwiftUI

/// Offered instead of onboarding when a fresh installation finds a Keychain backup of an earlier one.
struct DeviceStateRestoreView: View {
    let backup: DeviceStateBackup
    let onRestore: (_ includePumpState: Bool) -> Void
    let onSkip: () -> Void

    @State private var includePumpState = true
    @State private var confirmSkip = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "Auf diesem iPhone liegt eine Sicherung einer früheren Trio-Installation vom \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) (Version \(backup.appVersion))."
                    )
                }

                Section("Enthalten") {
                    if backup.restoresSettings {
                        Label("Einstellungen und Therapieprofile", systemImage: "slider.horizontal.3")
                    }
                    if let cgm = backup.cgmManagerIdentifier {
                        Label("CGM: \(cgm)", systemImage: "sensor.tag.radiowaves.forward")
                    }
                    if let pump = backup.pumpManagerIdentifier {
                        Toggle(isOn: $includePumpState) {
                            Label("Pumpe: \(pump)", systemImage: "cross.vial")
                        }
                    }
                }

                if backup.pumpManagerIdentifier != nil {
                    Section {
                        Text(
                            "Der Pumpenzustand enthält die Kopplung mit dem aktiven Pod bzw. der aktiven Pumpe. Ohne ihn kann ein laufender Pod nicht mehr gesteuert werden. Nach der Wiederherstellung den Pumpenstatus prüfen; meldet die Pumpe Kommunikationsfehler, Pod bzw. Pumpe neu einrichten."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Wiederherstellen und Trio beenden") {
                        onRestore(includePumpState && backup.pumpManagerIdentifier != nil)
                    }
                    .bold()
                    Text("Trio übernimmt die Sicherung beim nächsten Start. Danach Trio erneut öffnen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Ohne Wiederherstellung neu einrichten", role: .destructive) { confirmSkip = true }
                }
            }
            .navigationTitle("Sicherung gefunden")
        }
        .confirmationDialog(
            "Die Sicherung wird nach Abschluss der Einrichtung überschrieben.",
            isPresented: $confirmSkip,
            titleVisibility: .visible
        ) {
            Button("Neu einrichten", role: .destructive, action: onSkip)
        }
    }
}
