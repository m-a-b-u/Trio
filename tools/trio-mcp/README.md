# trio-mcp

Verbindet **Claude** (Claude Desktop, Claude Code, Cowork) per MCP mit **Trio** auf dem iPhone.

```
Claude ──MCP (stdio)──▶ trio-mcp mcp ──▶ trio-mcp serve (Relay, Port 8765) ◀──WLAN── Trio (iPhone)
```

**Sicherheitsmodell:** Claude kann Trios Einstellungen und Status lesen und Änderungen **vorschlagen**. In Trio
wird jeder Vorschlag erst nach Prüfung des Vorher/Nachher-Diffs und Freigabe mit **Face ID** übernommen.
Ablehnungen und Fehler werden an Claude zurückgemeldet.

## Einrichtung am Mac

```bash
cd ~/Developer/Trio/tools/trio-mcp     # Pfad deines Trio-Klons
npm install
node trio-mcp.mjs install-launchd      # Relay startet automatisch bei Anmeldung
node trio-mcp.mjs info                 # zeigt Server-URL + Token für Trio
```

Ohne launchd: `node trio-mcp.mjs serve` in einem Terminal laufen lassen.

## In Trio

Einstellungen → **Claude-Bridge (MCP)** → Server-URL + Token eintragen → „Claude-Bridge aktiv“ einschalten.
iPhone und Mac müssen im selben Netz sein (oder per Tailscale/VPN verbunden). Beim ersten Verbinden fragt iOS
nach „Lokales Netzwerk“ – erlauben.

## In Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "trio": {
      "command": "node",
      "args": ["/Users/DEINNAME/Developer/Trio/tools/trio-mcp/trio-mcp.mjs", "mcp"]
    }
  }
}
```

Falls Claude Desktop `node` nicht findet: statt `"node"` den vollen Pfad aus `which node` eintragen
(z.B. `/opt/homebrew/bin/node`). Claude Desktop neu starten. Für Claude Code: `claude mcp add trio -- node /Pfad/zu/trio-mcp.mjs mcp`.

## Tägliche Analyse & Companion-Web-App

Trio lädt zusätzlich den Verlauf der letzten **30 Tage** hoch (Glukose, Boli/SMB, KH, Temp-Basal,
Loop-Entscheidungen, TDD). Der Mac berechnet daraus Statistiken (TIR, CV, GMI, Tagesprofil, Mahlzeiten,
Hypos) und lässt **täglich** Claude einen Bericht mit Änderungsvorschlägen erstellen.

```bash
node trio-mcp.mjs set-api-key        # Anthropic-API-Key eingeben (bleibt nur am Mac, ~/.trio-mcp/config.json)
node trio-mcp.mjs set-time 07:00     # Uhrzeit der Tagesanalyse
node trio-mcp.mjs analyze            # sofort ausführen
node trio-mcp.mjs info               # zeigt auch den Link zur Web-App
```

**Web-App:** `http://<Mac-IP>:8765/app?token=<Token>` am iPhone in Safari öffnen → Teilen → „Zum Home-Bildschirm“.
Zeigt Status, Tagesbericht, Vorschläge (mit Status), Zeit im Zielbereich, Tagesprofil, Mahlzeiten und Tagesverlauf.

**Leitplanken der Tagesanalyse:** Vorschläge nur bei Mustern an ≥ 3 Tagen und ≥ 7 Tagen Daten, max. 2 Therapie-
Vorschläge pro Tag, Basal/ISF/KH-Faktor max. ±10 % pro Schritt (der Server blockiert hart alles über ±20 % bzw.
Einstellungen über ±30 %), Hypos haben Vorrang. Ältere offene Vorschläge der Tagesanalyse werden beim nächsten Lauf
zurückgezogen. Jede Änderung braucht weiterhin deine Face-ID-Freigabe in Trio.

## Tools

| Tool | Zweck |
|---|---|
| `trio_get_status` | Glukose, Trend, IOB, COB, letzter Loop |
| `trio_get_settings` | settings, preferences (oref), basal_profile, isf, carb_ratios, bg_targets, pump |
| `trio_propose_settings_change` | Schlüssel in settings/preferences ändern (Vorschlag) |
| `trio_propose_schedule` | 24h-Zeitplan ersetzen: Basal (U/h), ISF (mg/dL/IE), KH-Faktor (g/IE), Ziele (mg/dL) |
| `trio_get_history_stats` | 30-Tage-Statistik: TIR, Tagesprofil, Mahlzeiten, Hypos, TDD |
| `trio_get_daily_report` / `trio_run_daily_analysis` | Tagesbericht lesen / Analyse starten |
| `trio_list_proposals` / `trio_get_proposal` / `trio_cancel_proposal` | Vorschläge verfolgen |

Daten liegen in `~/.trio-mcp/` (`config.json` mit Token/API-Key, `db.json` mit Snapshot, Vorschlägen und Berichten, `history.json` mit dem 30-Tage-Verlauf).
