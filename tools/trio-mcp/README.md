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

## Tools

| Tool | Zweck |
|---|---|
| `trio_get_status` | Glukose, Trend, IOB, COB, letzter Loop |
| `trio_get_settings` | settings, preferences (oref), basal_profile, isf, carb_ratios, bg_targets, pump |
| `trio_propose_settings_change` | Schlüssel in settings/preferences ändern (Vorschlag) |
| `trio_propose_schedule` | 24h-Zeitplan ersetzen: Basal (U/h), ISF (mg/dL/IE), KH-Faktor (g/IE), Ziele (mg/dL) |
| `trio_list_proposals` / `trio_get_proposal` / `trio_cancel_proposal` | Vorschläge verfolgen |

Daten liegen in `~/.trio-mcp/` (`config.json` mit Token, `db.json` mit Snapshot und Vorschlägen).
