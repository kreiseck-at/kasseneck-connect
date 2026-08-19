# Kasseneck Connect

Lokaler Agent für die Browser-Kasse von **Kasseneck**. Er läuft als eigenständige
Binary auf dem Kassenrechner, koppelt sich mit der Kasse im Browser und übernimmt
das, was eine Webseite selbst nicht kann: **Netzwerk-Bondrucker finden und die
Beleg-Bytes der Kasse drucken** (TCP 9100 bzw. Epson ePOS). Später kommen das
Zahlungsterminal (v1.1) und die Selbstaktualisierung (v1.2) dazu.

Die Kasse erzeugt die ESC/POS-Bytes weiterhin selbst — Connect ist reiner Transport.

> Stand: Etappe v1.0 im Aufbau. Fertig sind Projektgerüst, Konfiguration und Log;
> die lokale API, Pairing und die Druckertreiber folgen.

## Befehle

```
kasseneck-connect <befehl>
```

| Befehl | Zweck |
|---|---|
| `run` | Agent starten (lokale API auf `127.0.0.1:27182`, Fallback 27183–27189) |
| `pair` | Kopplungscode für die Kasse anzeigen |
| `install-autostart` | Autostart einrichten (macOS LaunchAgent, Windows Aufgabenplanung, Linux systemd --user) |
| `uninstall-autostart` | Autostart entfernen |
| `doctor` | Diagnose ausgeben |
| `version` | Version ausgeben |

Bis auf `version` melden die Befehle derzeit „noch nicht verfügbar" und enden mit
Exit-Code 2.

## Konfigurationspfade

Konfiguration und Log liegen im Datenverzeichnis des Agenten:

| System | Verzeichnis |
|---|---|
| macOS | `~/Library/Application Support/KasseneckConnect` |
| Windows | `%ProgramData%\KasseneckConnect` |
| Linux | `$XDG_CONFIG_HOME/kasseneck-connect`, sonst `~/.config/kasseneck-connect` |

Darin: `config.json` (Port, Token-Hashes, Drucker, Terminal, Update-Kanal; atomar
geschrieben, Rechte 600) und `logs/connect.log` (täglich rotierend, 7 Dateien).
Die Umgebungsvariable `KASSENECK_CONNECT_HOME` überschreibt das Verzeichnis.

Gepflegt wird die Konfiguration ausschließlich über die lokale API aus der Kasse
heraus — Handarbeit in der Datei ist nicht nötig.

## Entwicklung

```bash
dart pub get
dart test
dart analyze
dart format .
dart compile exe bin/kasseneck_connect.dart -o build/kasseneck-connect
```

---

© 2026 Kreiseck – Software Solutions. Alle Rechte vorbehalten.
