# Trio für macOS – Entwicklungsstand

Ziel ist eine eigenständige Trio-App für macOS mit Omnipod DASH und Dexcom G7,
Menüleistenanzeige und Widgets auf Mac und iPhone. Der Mac soll ohne laufendes
iPhone arbeiten können. Manuelle Boli und wichtige manuelle Therapieänderungen
benötigen Touch ID; automatische Mikroboli des AID-Loops bleiben automatisch.

**Dieser Stand ist ein experimenteller Port, keine freigegebene Pumpensteuerung.**
Die Mac-App erlaubt beim Erstellen und Wiederherstellen von Gerätemanagern nur
Simulatoren. Die Sperre ist zur Übersetzungszeit festgelegt und lässt sich nicht
über Einstellungen, MCP, Umgebungsvariablen oder einen Startparameter abschalten.
Blockierte gespeicherte Gerätekonfigurationen werden beim Start nicht gelöscht.
Eine spätere ausdrückliche Auswahl eines anderen Geräts ersetzt dessen
Konfiguration weiterhin wie in Trio üblich.

## Bestandteile

| Bestandteil | Umsetzung |
| --- | --- |
| `TrioMac` / Schema `Trio Mac` | Vollständiger Trio-App-Quellbestand als Mac-Catalyst-Ziel, eigenes Bundle und URL-Schema `trio-mac` |
| `TrioMenuBar` / Schema `Trio Menu Bar` | Native SwiftUI-Menüleisten-App, über `SMAppService` aus Trio aktivierbar |
| `TrioMacWidgets` / Schema `Trio Mac Widgets` | Native macOS-Widget-Erweiterung, in der Mac-App eingebettet |
| iPhone-Widget | `Trio Status` in der vorhandenen LiveActivity-Erweiterung |
| `Shared/StatusWidget` | Gemeinsames, validiertes lokales Anzeigeformat und App-Group-Dateispeicher |
| `WidgetSnapshotPublisher` | Glukose/Trend und IOB/COB aus der lokalen Trio-Datenbank mit ursprünglichen Zeitstempeln |
| `DeviceOwnerAuthentication` | Frischer Touch-ID-Kontext auf dem Mac; kein Passwort-/Watch-Fallback und keine Wiederverwendung einer vorherigen Freigabe |
| `MacDeviceOperationPolicy` | Vorläufige Gerätesperre vor Konstruktoren, Wiederherstellung und Hersteller-Einrichtungsoberflächen |

Die Menüleiste zeigt standardmäßig nur „Trio“. Der Glukosewert lässt sich dort
ausdrücklich einblenden. Widgets und Menüleiste zeigen fehlende oder veraltete
Daten entsprechend an und lösen keine Therapieaktionen aus. Sie lesen den
lokalen Datenbestand des jeweiligen Geräts; eine Synchronisierung von Pumpen-
oder Sensorzuständen zwischen iPhone und Mac ist damit **nicht** implementiert.

Reservoir/Pumpenstatus sind im Anzeigeformat vorbereitet, werden vom Publisher
noch nicht befüllt: dafür fehlt eine einheitliche verlässlich datierte Quelle.
Unbekannte Werte bleiben leer. Widgets sind keine Echtzeit-Anzeige; macOS/iOS
bestimmen die Ausführung und Aktualisierungsrate von WidgetKit.

Watch-Anbindung, Garmin ConnectIQ, Live Activities und AlarmKit sind im Catalyst-
Ziel ausgegrenzt. iOS behält seine bisherigen Pfade. Alarmierung, Schlafzustand,
Wiederanlauf und Bluetooth-Reconnect auf dem Mac sind noch nicht abgenommen.

## Bisherige Prüfung (24.10.2026)

- Vollständiger unsignierter Debug-Build unter Xcode 27.1 erfolgreich. Die
  tatsächlichen Mach-O-Dateien enthalten `arm64` und `x86_64`: Host und 31
  eingebettete Frameworks sind Catalyst, Widget und Menüleisten-App natives
  macOS. 732 App-Quelldateien stimmen mit der gebauten Kopie überein; die 15
  ursprünglichen Projektdateien blieben beim isolierten Build unverändert.
- iPhone-17-Simulator mit iOS 26.5: acht ausgewählte Suiten, **67 Tests / 79
  Ausführungen**, kein Fehler, kein übersprungener Test. Enthalten sind die
  bisherigen KI-/Bridge-Suiten sowie Touch-ID-Policy und Mac-Gerätepolicy.
- Gemeinsames Anzeigeformat **7 Tests**, Menüleistenmodell **4 Tests** und
  isolierte Buildvorbereitung **7 Tests** erfolgreich. Die aus den tatsächlichen
  Methoden extrahierte Mac-Gerätewiederherstellung wurde zusätzlich mit
  Testdoubles auf Erhalt gesperrter Gerätezustände geprüft.
- Projekt-/Entitlement-Plists, Workflow-Syntax und Diffprüfung erfolgreich.
  Unabhängiges Review der Gerätesperren sowie der Target-/Embed-/App-Group-
  Konfiguration ohne verbleibenden Befund in diesem geprüften Umfang.

Die Mac-App wurde nicht gestartet oder installiert. Keine reale Kopplung,
Insulinabgabe, Touch-ID-Geräteabnahme, Notarisierung oder Verteilung erfolgt.
Die Angaben sind lokale Entwicklungsnachweise; es gibt dafür noch keinen
bestätigten Mac-CI-/Release-Lauf.

## Lokaler Build

Voraussetzungen: vollständiges Xcode, initialisierte Submodule, Python 3 und
Netzzugriff zum Auflösen der festgeschriebenen Swift-Package-Abhängigkeiten.
Mindestziele: macOS 14.6 / iOS 17.6 für Catalyst.

Die vorhandenen Treiberprojekte enthalten iOS-Einstellungen. Deshalb erstellt
der Wrapper eine unabhängige Quellenkopie außerhalb des Checkouts und ergänzt
die benötigten Catalyst-Einstellungen nur dort. Originalprojekte/Submodule
werden nicht geändert. Das native Widget und die Menüleisten-App behalten ihr
macOS-Ziel. Beide Deploymentwerte sind erforderlich, weil Xcode das effektive
macOS-Minimum für Catalyst aus dem iOS-Minimum ableitet.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  scripts/build-macos.sh --output /tmp/trio-macos-build -- \
  CODE_SIGNING_ALLOWED=NO DEVELOPER_TEAM=TRIOMACTST DEVELOPMENT_TEAM=TRIOMACTST
```

`TRIOMACTST` ist ausschließlich eine synthetische Kennung für den unsignierten
lokalen Build. Sie erteilt keine Apple-Berechtigungen. Der Aufruf setzt
`CODE_SIGNING_ALLOWED=NO`. Ergebnis und Manifest liegen im Ausgabeordner;
`--prepare-only` erstellt nur die Kopie, `--show-destinations` prüft die Ziele.
Keine globalen `SDKROOT`-, `SUPPORTED_PLATFORMS`- oder
`SUPPORTS_MACCATALYST`-Overrides hinzufügen: sie würden auch native Teilprodukte
auf Catalyst umstellen. Der Wrapper weist solche Overrides zurück.

```sh
python3 -B -m unittest discover -s scripts -p test_prepare_macos_workspace.py -v
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Shared/StatusWidget --scratch-path /tmp/trio-widget-tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path TrioMac/MenuBar --scratch-path /tmp/trio-menubar-tests
```

Zum Verteilen fehlen eigene Mac-Bundle-Registrierungen, passende Signierung,
App-Group-Zuordnungen und Profile. Das iPhone-Widget benötigt außerdem die neue
App-Group-Berechtigung der LiveActivity-Erweiterung in seinem Profil. Die lokale
Codeänderung im Fastlane-Identifier-Schritt ersetzt diese Portal-/Profilprüfung
nicht. Login-Item-Registrierung, Widget-Galerie und tatsächliche Touch-ID-Dialoge
müssen mit korrekt signierten Apps geprüft werden.

## Offene Voraussetzungen für echten DASH-/G7-Betrieb

1. **Aktive G7-Authentifizierung.** Das eingebundene G7SensorKit setzt die externe
   Dexcom-App für Kopplung und Sensorverwaltung voraus. Ein kompilierter Treiber
   allein erfüllt daher noch keinen Betrieb ohne iPhone. Die Untersuchung des
   aktiven xDrip-Verfahrens steht in [G7_AUTH_RESEARCH.md](G7_AUTH_RESEARCH.md).
2. **Alle manuellen Therapieänderungen vor dem Commit authentifizieren.** Der
   zentrale manuelle Boluspfad und die KI-Vorschlagsfreigabe sind bereits
   geschützt. Profil-/Limit-/Override-Editoren und Herstelleroberflächen haben
   zusätzliche Schreibpfade. Siehe [THERAPY_AUTH_AUDIT.md](THERAPY_AUTH_AUDIT.md).
   Ein globaler Authentifizierungshook an jedem Datenbankschreibvorgang wäre
   falsch: Statusspeicherung und bestätigte automatische Therapie müssen laufen.
3. **Exklusive Controller-Zuständigkeit.** DASH hat bereits einen direkten
   BLE-Treiber. Sein verschlüsselter Sitzungszustand einschließlich Zählern und
   noch unbestätigten Befehlen darf aber nicht parallel auf zwei Geräten
   verwendet werden. Ein Server-Lock verhindert keine Befehle eines getrennten
   alten Controllers. Sichere Übergabe, Crash-Wiederherstellung und Abgleich
   unbekannter Befehlsergebnisse sind noch nicht implementiert/abgenommen.
   Insbesondere wird keine Übernahme eines laufenden Pods durch Kopieren seiner
   Daten angeboten.
4. **Desktop-Betrieb abnehmen.** Bluetooth, Schlafen/Aufwachen, Verbindungsabbruch,
   Neustart, Uhrzeitänderungen, Benachrichtigungen, verweigerte Berechtigungen und
   paralleler Betrieb zweier Installationen benötigen reproduzierbare Tests.
5. **Signierung und Geräteabnahme.** Zuerst Simulatoren und Protokoll-Fixtures,
   dann dedizierte Testhardware in einer kontrollierten Umgebung. Kein Test darf
   eine laufende Therapie stillschweigend übernehmen oder unterbrechen.

Erst nach diesen Schritten kann die Gerätesperre in einem separat geprüften
Änderungssatz entfallen. Ein erfolgreicher Build und synthetische Tests belegen
keine klinische Eignung, keine sichere Controller-Übergabe und keine erfolgreich
durchgeführte reale Insulinabgabe.
