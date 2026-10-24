import AppKit
import SwiftUI

@main struct TrioMenuBarApp: App {
    @NSApplicationDelegateAdaptor(TrioMenuBarAppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("showGlucoseInMenuBar") private var showGlucoseInMenuBar = false
    @StateObject private var model = TrioMenuBarStatusModel()

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            TrioMenuBarPanel(model: model)
        } label: {
            Label(model.presentation.menuBarTitle(showGlucose: showGlucoseInMenuBar), systemImage: "drop.fill")
                .privacySensitive()
                .task { await model.observeLocalSnapshot() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TrioMenuBarSettingsView()
        }
    }
}

private struct TrioMenuBarPanel: View {
    @ObservedObject var model: TrioMenuBarStatusModel
    @State private var openingFailed = false

    private var presentation: TrioMenuBarPresentation { model.presentation }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trio Status")
                .font(.headline)

            if let snapshot = presentation.snapshot {
                glucose(snapshot)
                Divider()
                calculation(snapshot)
                Divider()
                pump(snapshot)
            } else {
                ContentUnavailableView(
                    presentation.loadFailed ? "Status nicht verfügbar" : "Noch kein Status",
                    systemImage: "waveform.path.ecg",
                    description: Text("Trio öffnen, um den lokalen Status bereitzustellen.")
                )
            }

            Divider()
            HStack {
                Button("Trio öffnen", systemImage: "arrow.up.forward.app") {
                    openingFailed = !NSWorkspace.shared.open(URL(string: "trio-mac://")!)
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Einstellungen der Menüleiste")
                .accessibilityLabel("Einstellungen der Menüleiste")
            }
            if openingFailed {
                Text("Trio konnte nicht geöffnet werden. Starte Trio im Programme-Ordner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 330)
        .onAppear { model.reload() }
    }

    private func glucose(_ snapshot: TrioStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glukose").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(presentation.glucoseValue() ?? "—")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(presentation.glucoseFreshness == .stale)
                Text(snapshot.unit.rawValue).foregroundStyle(.secondary)
                if presentation.glucoseFreshness == .fresh, let trend = snapshot.trend, !trend.symbol.isEmpty {
                    Text(trend.symbol).font(.title2)
                }
            }
            .privacySensitive()
            sourceDate(snapshot.glucoseDate, freshness: presentation.glucoseFreshness)
        }
    }

    private func calculation(_ snapshot: TrioStatusSnapshot) -> some View {
        let freshness = snapshot.determinationFreshness(at: presentation.now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                metric("IOB", value: snapshot.iob, unit: "U", freshness: freshness)
                Spacer()
                metric("COB", value: snapshot.cob, unit: "g", freshness: freshness)
            }
            sourceDate(snapshot.determinationDate, freshness: freshness)
        }
    }

    private func pump(_ snapshot: TrioStatusSnapshot) -> some View {
        let freshness = snapshot.pumpFreshness(at: presentation.now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pumpe").font(.subheadline).foregroundStyle(.secondary)
                    Text(freshness == .unavailable ? "—" : snapshot.pumpStatus ?? "—")
                        .fixedSize(horizontal: false, vertical: true)
                        .privacySensitive()
                }
                Spacer()
                metric("Reservoir", value: snapshot.reservoir, unit: "U", freshness: freshness)
            }
            sourceDate(snapshot.pumpDate, freshness: freshness)
        }
    }

    private func metric(_ label: LocalizedStringKey, value: Double?, unit: String, freshness: TrioStatusFreshness) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            if freshness != .unavailable, let value {
                Text(value.formatted(.number.precision(.fractionLength(0 ... 2))) + " " + unit)
                    .monospacedDigit()
                    .strikethrough(freshness == .stale)
                    .privacySensitive()
            } else {
                Text("—")
            }
        }
    }

    private func sourceDate(_ date: Date?, freshness: TrioStatusFreshness) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let date {
                Text("Stand: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .privacySensitive()
            }
            if freshness == .stale {
                Label("Veraltet · mindestens 6 Minuten alt", systemImage: "clock.badge.exclamationmark")
            } else if freshness == .unavailable {
                Text("Kein aktueller Zeitstempel verfügbar")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct TrioMenuBarSettingsView: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("showGlucoseInMenuBar") private var showGlucoseInMenuBar = false

    var body: some View {
        Form {
            Toggle("Menüleistensymbol anzeigen", isOn: $showMenuBarExtra)
            Toggle("Glukosewert in der Menüleiste anzeigen", isOn: $showGlucoseInMenuBar)
                .disabled(!showMenuBarExtra)
            Text("Der Glukosewert ist für andere Personen sichtbar, die deinen Bildschirm sehen können.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Ausgeblendet? Öffne Trio Menüleiste erneut, um diese Einstellungen anzuzeigen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }
}

/// Reopening a hidden accessory app must offer a way to restore its menu item.
@MainActor private final class TrioMenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard urls.contains(where: {
            $0.scheme?.lowercased() == "trio-menubar" && $0.host == "settings" &&
                ($0.path.isEmpty || $0.path == "/") && $0.user == nil && $0.password == nil &&
                $0.port == nil && $0.query == nil && $0.fragment == nil
        }) else { return }
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Trio Menüleiste"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TrioMenuBarSettingsView())
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
