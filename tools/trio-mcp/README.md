# trio-mcp

Verbindet **Claude und ChatGPT über MCP** mit **Trio** auf dem iPhone. Die Bedienung erfolgt im
normalen Chat des jeweiligen Clients; eine eigene Website ist dafür nicht erforderlich.

```
Claude Desktop ──MCP (stdio)────────────────────────┐
Claude / ChatGPT ──HTTPS + OAuth──▶ trio-mcp remote ─┴──▶ Relay ◀── Trio
```

**Freigabe:** Die KI liest den synchronisierten Stand und erstellt Vorschläge. Jede Änderung wird in Trio
mit Vorher/Nachher-Diff angezeigt und erst nach lokaler Authentifizierung (Face ID oder Gerätecode)
übernommen. Es gibt kein MCP-Tool zum direkten Anwenden oder zur Bolusabgabe.

**Kein Inferenz-API-Key nötig:** Lesen, Statistiken und manuelle Vorschläge funktionieren über den
MCP-Client ohne Anthropic- oder OpenAI-Modellschlüssel im Relay. Die unten beschriebenen Tagesanalysen
und die Mahlzeiten-KI sind zusätzliche Funktionen: Cloud-Anbieter nutzen eigene API-Konfigurationen;
Apple Intelligence verarbeitet Mahlzeitentext lokal auf dem iPhone.

## Einrichtung am Mac

```bash
cd ~/Developer/Trio/tools/trio-mcp
npm install
node trio-mcp.mjs install-launchd
node trio-mcp.mjs setup                # Private QR-Datei am Mac erzeugen
```

Ohne launchd: `node trio-mcp.mjs serve`. `setup` erzeugt `~/.trio-mcp/setup.html` mit Dateirechten 0600.
Diese Datei am Mac öffnen und den QR-Code mit der iPhone-Kamera scannen; der aktuelle Trio-Build öffnet
die lokale Einrichtung. Server prüfen, Verbindung testen und bestätigen. Der Test ruft nur das
authentifizierte `/api/health` auf; erst die aktivierte Synchronisierung überträgt Einstellungen und Verlauf.

Standardadresse ist der lokale Mac-Hostname, z. B. `http://Odin.local:8765`. Alternativ:
`node trio-mcp.mjs setup http://192.168.1.20:8765`. HTTP ist auf `.local`, `localhost` und private,
link-lokale oder Loopback-IPv4-Adressen begrenzt; IPv6 benötigt HTTPS. iPhone und Mac brauchen eine direkte
Netzwerkverbindung, z. B. WLAN oder VPN; iOS muss den Zugriff auf das lokale Netzwerk erlauben.

Der QR-Code wird offline mit macOS CoreImage erzeugt und enthält den **dauerhaften Bridge-Token**,
keinen Einmalcode. Datei/QR privat halten, nicht weitergeben oder ins Repository aufnehmen und nach
der Einrichtung löschen. Die CLI gibt nur Dateipfad und Server aus. Anbieter-Schlüssel werden nicht übertragen.
Manuelle Einrichtung bleibt unter **Einstellungen → KI → KI-Bridge (MCP)** möglich;
`node trio-mcp.mjs info` zeigt dafür Serveradresse und Token an.

## Native Chat-Clients

### Claude Desktop am Mac

Der vorhandene Server spricht MCP über stdio. Beispiel für
`~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Den Node-Pfad gegebenenfalls anpassen und den Client neu starten. Das Relay muss laufen.
Die Auswahl des Chat-Clients legt nicht den Anbieter der optionalen automatischen Tagesanalyse fest.

Stand 24.10.2026: Die vorhandene lokale Claude-Desktop-Konfiguration und der MCP-Handshake mit
**11 Tools** wurden geprüft. Die Bedienung in der Claude-App wurde damit noch nicht abgenommen.

### ChatGPT über Secure MCP Tunnel

Der offizielle OpenAI-Tunnel kann direkt das vorhandene stdio-Kommando starten. Ein öffentlicher
Trio-Server oder eine eigene Weboberfläche ist dafür nicht nötig. Die ChatGPT-Verbindung ist
**noch nicht fertig eingerichtet oder durch einen Chat-Aufruf bestätigt**.

1. In den [Platform-Tunneleinstellungen](https://platform.openai.com/settings/organization/tunnels)
   einen Tunnel anlegen bzw. wiederverwenden und dem richtigen ChatGPT-Workspace zuordnen.
2. Den offiziellen `tunnel-client` am Mac auf das Kommando `node /ABSOLUTER/PFAD/trio-mcp.mjs mcp`
   konfigurieren und betreiben. Er benötigt eine Tunnel-ID und einen separat berechtigten Runtime-Key
   für den Tunnelbetrieb; dieser ist kein Modellschlüssel für Trio-Tagesanalysen.
3. Unter [ChatGPT Plugins](https://chatgpt.com/plugins) **Add custom MCP server → Connection: Tunnel**
   wählen, denselben Tunnel verbinden und das Plugin im normalen Chat auswählen.

Account-/Workspace-Freigaben, laufender Tunnel und die Verfügbarkeit im gewünschten nativen bzw.
mobilen ChatGPT-Client müssen noch geprüft werden. Erst ein erfolgreicher Tool-Aufruf aus diesem
Client bestätigt die Verbindung. Ein OpenAI-Inferenz-API-Key allein richtet sie nicht ein.
Tunnel-Zugangsdaten gehören in eine private lokale Einrichtung, nicht ins Repository oder in den Chat.
Der Tunnel soll den MCP-stdio-Prozess verbinden; der bestehende REST-Relay-Port mit seinen internen
iPhone-Endpunkten wird dafür nicht öffentlich freigegeben.

Anleitung: [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels),
[MCP in ChatGPT verbinden und testen](https://developers.openai.com/plugins/deploy/connect-chatgpt).

### Remote-MCP für Claude und ChatGPT

Der gemeinsame Remote-Zugang verwendet **Streamable HTTP und OAuth mit PKCE S256**. Er bietet dieselben
11 Werkzeuge wie stdio. Der angemeldete Chat-Assistent benötigt dafür keinen Modell-API-Key im Relay.
Die lokale Claude-Desktop-Konfiguration wird nicht auf iOS übertragen; dort den Remote-Connector verwenden.

```bash
node trio-mcp.mjs remote-setup https://DEINE-MCP-DOMAIN
node trio-mcp.mjs remote
node trio-mcp.mjs remote-info
```

`remote` lauscht ausschließlich auf **127.0.0.1:8766**. Einen HTTPS-Reverse-Proxy/Tunnel ausschließlich
auf diesen Port richten, **niemals auf den iPhone-REST-Relay-Port 8765**. Bei einer festen Domain startet
`node trio-mcp.mjs install-remote-launchd` den Remote-Dienst automatisch am Mac; der HTTPS-Proxy braucht
einen eigenen laufenden Dienst. Mac und Relay müssen erreichbar bleiben, damit aktuelle Daten verfügbar sind.
Die iPhone-Synchronisierung verwendet weiterhin die bestehende lokale Verbindung bzw. ein VPN.

Als Connector-URL in Claude oder ChatGPT **`https://DEINE-MCP-DOMAIN/mcp`** eintragen und OAuth wählen.
Client-ID und Client-Secret leer lassen: Die Clients registrieren sich automatisch als öffentliche
PKCE-Clients. Im anschließenden Trio-Anmeldedialog den privaten Schlüssel aus
`~/.trio-mcp/remote-owner-key.txt` eingeben und den angezeigten Client samt Rücksprungadresse prüfen.
Dieser Schlüssel ist separat vom Bridge-Token und von Anbieter-API-Keys. Die Seite dient ausschließlich
der Anmeldung; Trio wird anschließend im normalen Chat bedient.

Die Einrichtung speichert Schlüssel und Konfiguration mit Dateirechten 0600, OAuth-Grants nur als
Token-Hashes. Access-Tokens gelten eine Stunde, Refresh-Tokens 30 Tage und werden bei Nutzung ersetzt.
Callbacks sind auf Claude und ChatGPT begrenzt. Ein Wechsel der öffentlichen Adresse verwendet getrennte
OAuth-Grants und erfordert erneutes Verbinden. Zum Widerruf den Connector trennen; unterstützt der
Client keine Token-Revocation, den Remote-Dienst stoppen und die zugehörige `remote-auth-*.json` entfernen
(dadurch werden alle Clients dieser Adresse abgemeldet).

Ein **Cloudflare Quick Tunnel** eignet sich für einen vorläufigen Test. Seine Adresse ist nicht dauerhaft,
ändert sich bei einem neuen Tunnel und muss dann mit `remote-setup` aktualisiert werden. HTTPS endet bei
Cloudflare; der Tunnelanbieter verarbeitet den Verkehr. Der Server verwendet JSON-Antworten ohne SSE,
da Quick Tunnels keine SSE-Dauerstreams unterstützen. Für regelmäßige Nutzung eine feste Domain mit
verwaltetem Tunnel oder HTTPS-Reverse-Proxy verwenden.

Der Teststarter übernimmt die wechselnde Adresse und startet beide Prozesse zusammen:
`node remote-test-tunnel.mjs /ABSOLUTER/PFAD/cloudflared`. Den normalen `remote`-Dienst vorher stoppen,
da der Starter denselben Port benötigt. Bei Abbruch oder Ausfall eines Prozesses beendet er beide.
Es gibt keinen automatischen Neustart mit einer anderen Adresse. `remote-info` zeigt die gespeicherte
Adresse, prüft aber nicht, ob der Tunnel noch läuft. Der Teststarter und die festen LaunchAgents sind
alternative Betriebsarten; nur eine davon gleichzeitig verwenden.

Protokolltests prüfen OAuth, geschützten Zugriff und MCP-Werkzeuge mit synthetischen Daten. Erst ein
Tool-Aufruf im gewünschten nativen Client bestätigt dessen tatsächliche Verbindung; Account-/Workspace-
Verfügbarkeit und mobile Unterstützung müssen dort geprüft werden.

Referenzen: [Claude-Authentifizierung](https://claude.com/docs/connectors/building/authentication),
[ChatGPT-OAuth](https://developers.openai.com/plugins/build/auth),
[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).

## Optionale API-Funktionen: Tagesanalyse

Anbieter und Zugangsdaten am Mac sind unabhängig von der Mahlzeiten-KI am iPhone. Die Tagesanalyse
(`relay_config`) unterstützt weiterhin ausschließlich Anthropic, OpenAI und OpenAI-kompatible APIs;
Apple Intelligence ist nur als Mahlzeitenanbieter auf dem iPhone verfügbar.
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

## Optionale Mahlzeiten-KI auf dem iPhone

In Trio: **Einstellungen → KI → KI-Anbieter für Mahlzeiten**.

**Apple Intelligence (offline):** Benötigt iOS 26 oder neuer, ein geeignetes Gerät, aktivierte
Apple Intelligence und bereits geladene Systemmodelle. Im Behandlungsdialog **Mahlzeit mit KI schätzen**
wählen und die Mahlzeit als Text mit Mengen beschreiben, z. B. „150 g Naturjoghurt und 30 g Haferflocken“.
Dieser Anbieter verarbeitet ausschließlich Text, keine Fotos. Er benötigt weder Modell-ID noch API-Key,
Mac oder Cloud-Verbindung. Ist das lokale Modell nicht verfügbar, zeigt Trio den Grund an und wechselt
nicht automatisch zu einem Cloud-Anbieter.

Die lokale Nährwertschätzung ist experimentell: Das Modell schätzt Lebensmittelwerte pro 100 g, Trio
berechnet daraus die Portionen und Summen. Das verhindert Rechenfehler bei der Skalierung, bestätigt
aber nicht die Richtigkeit der vom Modell geschätzten Lebensmittelwerte. Die Anzeige kennzeichnet
das Ergebnis deshalb ausdrücklich als ungeprüfte Schätzung; Werte vor der Übernahme kontrollieren.

**Anthropic, OpenAI und OpenAI-kompatibel:** Modell-ID, gegebenenfalls Basis-URL und API-Key speichern.
Schlüssel liegen im iPhone-Schlüsselbund, getrennt nach Anbieter und bei eigenen APIs nach Endpunkt.
Das Modell muss Bilder verstehen; beim Schätzen werden das ausgewählte Foto und der optionale Hinweis
an diesen Anbieter gesendet. Ein OpenAI-kompatibler Endpunkt ohne Authentifizierung kann ohne Schlüssel
verwendet werden.

Die zurückgegebenen Nährwerte bleiben bei allen Anbietern editierbar und füllen erst nach Übernahme
das normale Trio-Formular vor; dadurch wird nichts automatisch dosiert. Ein Anbieterwechsel erhält die
gespeicherten Cloud-Konfigurationen und Zugangsschlüssel.

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

Das iPhone-Ziel `ai_meal` erlaubt zusätzlich `provider: "apple-intelligence"`. Auch bei aktivem Apple
bleiben `anthropicModel`, `openAIModel`, `openAICompatibleModel` und `customBaseURL` als gespeicherte
Cloud-Konfiguration im Katalog erreichbar. Dadurch kann ein Vorschlag Anbieter und Modell/URL gemeinsam
wechseln. Die Feldhinweise kennzeichnen, dass Apple diese Werte nicht verwendet; Apple benötigt keinen
API-Key und bietet dafür keine Schlüssel-Aktion im Katalog an.

Nach lokaler Authentifizierung reserviert das iPhone einen Vorschlag auf dem Relay (`applying`).
Ab dann können ein paralleler Chat oder ein erneuter Tageslauf ihn nicht mehr zurückziehen. Die App
prüft die Vorschau nochmals vor dem Anwenden. Wird die App dabei beendet oder ist die Rückmeldung
unterbrochen, bleibt das Ergebnis bewusst unbestätigt; es wird keine möglicherweise bereits erfolgte
Pumpenaktion automatisch wiederholt. Den tatsächlichen Zustand am iPhone prüfen.

## Ablauf der optionalen Tagesanalyse

Trio lädt bis zu **30 Tage Verlauf** zum Relay: Glukose, Insulin, KH, Loop-Entscheidungen und TDD.
Der Mac berechnet Statistiken und sendet diese zusammen mit Einstellungen und bisherigen Entscheidungen
zur konfigurierten Analyse-API. Der Anbieter wird im Bericht gespeichert.

`analyze` benötigt das laufende Relay. CLI, MCP, Web-App und Scheduler teilen dieselbe Analyse-Sperre;
parallele Synchronisierungen und iPhone-Entscheidungen bleiben während der Analyse erhalten.

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

Die bisherige Companion-Web-App bleibt als optionale Ansicht für Berichte, Konfigurationsstatus,
Vorschläge und Statistiken vorhanden. Sie ist keine Voraussetzung für die Bedienung in Claude oder
ChatGPT. Berichte und Vorschläge sind auch über die unten aufgeführten MCP-Tools erreichbar.

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
