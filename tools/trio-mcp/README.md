# trio-mcp

Verbindet **MCP-fähige KI-Assistenten** mit **Trio** auf dem iPhone. Mahlzeitfotos und Tagesanalysen
unterstützen **Anthropic**, **OpenAI** und **OpenAI-kompatible APIs**.

```
KI-Assistent ──MCP (stdio)──▶ trio-mcp mcp ──▶ trio-mcp serve ◀──WLAN── Trio
                                                   │
                                     gewählter Analyseanbieter
```

**Freigabe:** Die KI liest den synchronisierten Stand und erstellt Vorschläge. Jede Änderung wird in Trio
mit Vorher/Nachher-Diff angezeigt und erst nach lokaler Authentifizierung (Face ID oder Gerätecode)
übernommen. Es gibt kein MCP-Tool zum direkten Anwenden oder zur Bolusabgabe.

## Einrichtung am Mac

```bash
cd ~/Developer/Trio/tools/trio-mcp
npm install
node trio-mcp.mjs install-launchd
node trio-mcp.mjs info                 # Server-URL + Token für Trio, Companion-Link
```

Ohne launchd: `node trio-mcp.mjs serve`. In Trio unter **Einstellungen → KI → KI-Bridge (MCP)**
URL und Token eintragen und verbinden. iPhone und Mac brauchen eine direkte Netzwerkverbindung,
z. B. WLAN oder VPN; iOS muss den Zugriff auf das lokale Netzwerk erlauben.

## Anbieter für Tagesanalysen wählen

Anbieter und Zugangsdaten am Mac sind unabhängig von der Konfiguration für Mahlzeitfotos am iPhone.
Bestehende Anthropic-Schlüssel und Modellwerte bleiben beim Upgrade erhalten. Ein Anbieterwechsel
übernimmt keine fremden Schlüssel oder Modellnamen. Es gibt keinen automatischen Anbieter-Fallback.

```bash
# Anthropic
node trio-mcp.mjs set-provider anthropic
node trio-mcp.mjs set-model DEINE_ANTHROPIC_MODELL_ID
node trio-mcp.mjs set-api-key

# OpenAI (Responses API; eigenen API-Key und Modell-ID verwenden)
node trio-mcp.mjs set-provider openai
node trio-mcp.mjs set-model DEINE_OPENAI_MODELL_ID
node trio-mcp.mjs set-api-key

# OpenAI-kompatibler Anbieter, Gateway oder lokaler Server (Chat Completions)
node trio-mcp.mjs set-provider openai-compatible
node trio-mcp.mjs set-base-url https://dein-anbieter.example/v1
node trio-mcp.mjs set-model DEINE_MODELL_ID
node trio-mcp.mjs set-api-key           # entfällt bei einem Endpunkt ohne Authentifizierung

node trio-mcp.mjs provider-status     # Konfigurationsstatus ohne Schlüssel
node trio-mcp.mjs set-time 07:00
node trio-mcp.mjs analyze
```

`set-api-key` fragt den Schlüssel lokal ab; keinen Schlüssel als Kommandozeilenargument verwenden.
Die Konfiguration liegt mit Dateirechten 0600 unter `~/.trio-mcp/config.json`. Eigene Endpunkte brauchen
HTTPS; HTTP ist nur auf Loopback erlaubt. Die Basis-URL endet üblicherweise auf `/v1`, nicht auf
`/chat/completions`. Schlüssel eigener Endpunkte sind an die vollständige normalisierte Basis-URL
gebunden. Bei deren Änderung entfernt die CLI den alten Schlüssel. HTTP-Weiterleitungen werden abgewiesen.

OpenAI und eigene Endpunkte haben absichtlich keine vorgewählte Modell-ID. Für Tagesanalysen muss das
gewählte Modell Function Calling mit dem jeweiligen API-Format unterstützen. „OpenAI-kompatibel“
bezeichnet hier Chat Completions mit `tools`, erzwungenem `tool_choice` und JSON-Funktionsargumenten;
reine Text- oder Embedding-Endpunkte reichen nicht. OpenAI selbst nutzt die Responses API.

Der bisherige Anthropic-Standard `claude-sonnet-4-5` bleibt für bestehende Konfigurationen erhalten;
Anthropic kündigt seine Abschaltung für den 30. November 2026 an. Ein verfügbares Modell explizit
konfigurieren ([Anthropic-Abkündigungen](https://platform.claude.com/docs/en/about-claude/model-deprecations)).

## Mahlzeitfotos

In Trio: **Einstellungen → KI → KI-Anbieter für Mahlzeitfotos**. Anbieter, Modell-ID, gegebenenfalls
Basis-URL und API-Key speichern. Schlüssel liegen im iPhone-Schlüsselbund, getrennt nach Anbieter und
bei eigenen APIs nach Endpunkt. Das Modell muss Bilder verstehen. Ein Endpunkt ohne Authentifizierung
kann bei „OpenAI-kompatibel“ ohne Schlüssel verwendet werden.

Im Behandlungsdialog **Mahlzeit per Foto schätzen (KI)** wählen. Nur das ausgewählte Foto und der
optionale Hinweis werden an diesen Anbieter gesendet. Die zurückgegebenen Nährwerte bleiben editierbar
und füllen erst nach Übernahme das normale Trio-Formular vor; dadurch wird nichts automatisch dosiert.

## MCP-Client

Der MCP-Server ist anbieterunabhängig. Jeder Client mit lokalem MCP-stdio-Support kann ihn starten.
Beispiel für Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "trio": {
      "command": "/opt/homebrew/bin/node",
      "args": ["/Users/DEINNAME/Developer/Trio/tools/trio-mcp/trio-mcp.mjs", "mcp"]
    }
  }
}
```

Den Node-Pfad gegebenenfalls anpassen und den Client neu starten. Die Auswahl des MCP-Clients legt
nicht den Anbieter der automatischen Tagesanalyse fest. Ein OpenAI-API-Key verbindet auch nicht
automatisch die ChatGPT-Web-App mit einem lokalen stdio-Server.

## Einstellungen entdecken und ändern

Zuerst `trio_get_settings_catalog` aufrufen. Der Katalog kommt vom aktuellen iPhone-Snapshot und enthält
für jeden Eintrag `target`, `key`, `type` und `access`; schreibbare Einstellungen enthalten außerdem
`current` und `constraints`. Bei lokalen Aktionen können diese Angaben fehlen. Dadurch sieht der
Assistent auch zusätzliche Einstellungsbereiche, Arrays und Objekte statt nur skalare Algorithmuswerte.

- `proposal`: über `trio_propose_settings_change` änderbar; anschließend auf dem iPhone prüfen und freigeben.
- `action`: der angegebene lokale Bedien- oder Autorisierungsschritt ist erforderlich.
- Zeitpläne: über `trio_propose_schedule` als vollständigen Tagesplan übertragen.

Zentrale Trio- und oref-Einstellungen, Pumpenlimits, Alarme, App-Optionen, KI-Mahlzeitkonfiguration,
Bridge- und Nightscout-Verbindung, Diagnosedaten-Freigabe, CGM-Simulator und Vorlagen für Mahlzeiten,
Overrides und temporäre Ziele werden über ihre jeweiligen Speicher- und Validierungswege verarbeitet.
Aktive Therapievorlagen bleiben unverändert; Vorlagen werden hier ausschließlich verwaltet, nicht aktiviert.
Die vorhandenen Typen, Wertebereiche und benötigten Folgeaktionen werden auf dem iPhone erneut geprüft.
Zugangsschlüssel werden nie als aktuelle Werte exportiert. Systemberechtigungen, Anmeldung und
Gerätekopplung bleiben lokale Schritte; der Katalog kennzeichnet sie ausdrücklich. Auch herstellerinterne
Pumpen-/CGM-Einstellungen ohne öffentliche Schreibschnittstelle (insbesondere LibreTransmitter) sind
lokale Aktionen. Diese Optionen sind derzeit **nicht** per KI beschreibbar; dafür wäre ein validierter
Adapter im jeweiligen Herstellermodul nötig.

Die Mac-Analyseeinstellungen stehen im Ziel `relay_config` (`provider`, `model`, `baseURL`, `analysisTime`).
Auch sie werden erst nach iPhone-Freigabe gespeichert. Bei einem gleichzeitigen Konfigurationswechsel
wird ein veralteter Vorschlag abgewiesen. Bei Anbieterwechsel gegebenenfalls Modell und Basis-URL im
selben Vorschlag angeben. API-Schlüssel am Mac lokal eingeben.

Nach lokaler Authentifizierung reserviert das iPhone einen Vorschlag auf dem Relay (`applying`).
Ab dann können ein paralleler Chat oder ein erneuter Tageslauf ihn nicht mehr zurückziehen. Die App
prüft die Vorschau nochmals vor dem Anwenden. Wird die App dabei beendet oder ist die Rückmeldung
unterbrochen, bleibt das Ergebnis bewusst unbestätigt; es wird keine möglicherweise bereits erfolgte
Pumpenaktion automatisch wiederholt. Den tatsächlichen Zustand am iPhone prüfen.

## Tagesanalyse und Companion-Web-App

Trio lädt bis zu **30 Tage Verlauf** zum Relay: Glukose, Insulin, KH, Loop-Entscheidungen und TDD.
Der Mac berechnet Statistiken und sendet diese zusammen mit Einstellungen und bisherigen Entscheidungen
zur konfigurierten Analyse-API. Der Anbieter wird im Bericht gespeichert.

`analyze` benötigt das laufende Relay. CLI, MCP, Web-App und Scheduler teilen dieselbe Analyse-Sperre;
parallele Synchronisierungen und iPhone-Entscheidungen bleiben während der Analyse erhalten.

Die Web-App ist unter dem von `info` ausgegebenen Link erreichbar. Auf dem iPhone in Safari öffnen
und bei Bedarf zum Home-Bildschirm hinzufügen. Sie zeigt Berichte, Konfigurationsstatus, Vorschläge,
Glukose-Statistiken und Verlauf.

Automatische Vorschläge benötigen mindestens sieben Tage Verlauf mit Messwerten an sieben verschiedenen
Tagen. Höchstens zwei neu erstellte automatische Vorschläge pro Kalendertag; Ablehnung oder Rücknahme
setzen das Kontingent nicht zurück. Der Server blockiert Zeitplanänderungen über ±20 % und Änderungen
skalarer numerischer Einstellungswerte über ±30 %; beide Zielgrenzen werden geprüft. Diese relative
Schrittgrenze gilt nicht für Zahlen innerhalb verschachtelter Objekte oder Listen; dort greifen die
jeweiligen Typ- und Werteprüfungen am iPhone sowie die lokale Freigabe. Fehlende Vergleichspläne und
skalare Änderungen ausgehend von null werden blockiert. Der Prompt verlangt zusätzlich wiederkehrende Muster,
kleinere Schritte und Vorrang für Hypoglykämien. Diese medizinischen Promptregeln ersetzen keine
persönliche Prüfung. Ein erneuter Lauf zieht offene automatische Vorschläge zurück und kann wegen
des Tageslimits keinen Ersatz erstellen.

## Tools

| Tool | Zweck |
|---|---|
| `trio_get_status` | Letzter synchronisierter Zustand mit Alter |
| `trio_get_settings_catalog` | Einstellungsbereiche, Werte, Typen, Grenzen und Schreibwege |
| `trio_get_settings` | Einen Katalogbereich oder alle Einstellungen lesen |
| `trio_propose_settings_change` | Skalare oder verschachtelte Einstellungen zur Freigabe vorschlagen |
| `trio_propose_schedule` | Basal, ISF, KH-Faktor oder BG-Zielplan vorschlagen |
| `trio_get_history_stats` | Bis zu 30 Tage Statistiken |
| `trio_get_daily_report` / `trio_run_daily_analysis` | Bericht lesen / Analyse starten |
| `trio_list_proposals` / `trio_get_proposal` / `trio_cancel_proposal` | Vorschläge verfolgen oder zurückziehen |

## Tests und API-Referenzen

`npm test` prüft Relay, Konfiguration, Katalog und die drei API-Formate ausschließlich mit synthetischen
Daten und lokalen API-Attrappen. Installierte Relay-Daten, echte Zugangsdaten und reale Therapieeinstellungen
werden dafür nicht verwendet. Die Simulator-CI kompiliert die App und führt die Swift-Provider-,
Katalog- und Diff-Tests aus. Echte Modellqualität und die Freigabe an einem physischen iPhone brauchen
separate Abnahme.

Requestformate: [OpenAI Bilder](https://developers.openai.com/api/docs/guides/images-vision),
[OpenAI Function Calling](https://developers.openai.com/api/docs/guides/function-calling).
