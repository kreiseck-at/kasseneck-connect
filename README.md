# Kasseneck Connect

Lokaler Agent für die Browser-Kasse von **Kasseneck**. Er läuft als eigenständige
Binary auf dem Kassenrechner, koppelt sich mit der Kasse im Browser und übernimmt
das, was eine Webseite selbst nicht kann: **Netzwerk-Bondrucker finden und die
Beleg-Bytes der Kasse drucken** (TCP 9100 bzw. Epson ePOS). Später kommen das
Zahlungsterminal (v1.1) und die Selbstaktualisierung (v1.2) dazu.

Die Kasse erzeugt die ESC/POS-Bytes weiterhin selbst — Connect ist reiner Transport.

> Stand: Etappe v1.0 im Aufbau. Fertig sind Projektgerüst, Konfiguration, Log,
> lokale API mit Kopplung sowie die Netzwerkdrucker samt Suche und
> Warteschlange; offen sind `/v1/events`, Autostart und die Installer.

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

`run`, `pair` und `version` sind gebaut; die übrigen Befehle melden derzeit
„noch nicht verfügbar" und enden mit Exit-Code 2.

`run` läuft, bis SIGINT/SIGTERM kommt. Ist noch kein Gerät gekoppelt, erzeugt der
Start einen sechsstelligen Code (10 Minuten gültig), schreibt ihn ins Log und
öffnet `https://kasse.kasseneck.at/connect#code=…&port=…` im Standardbrowser.
`KASSENECK_CONNECT_NO_BROWSER=1` unterdrückt das Öffnen; `pair` zeigt jederzeit
einen frischen Code an — auch neben dem laufenden Agenten.

## Drucker über die lokale API

Alle Pfade brauchen den Kopplungstoken (`Authorization: Bearer …`) und eine
erlaubte Herkunft; Fachfehler kommen mit HTTP 200 und `{ok: false, error: …}`.

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/v1/printers` | konfigurierte Drucker samt Zustand (`?probe=0` fragt die Geräte nicht an) |
| PUT | `/v1/printers` | anlegen — `{name, kind, host, port?, devid?}`, die ID vergibt der Agent |
| PUT | `/v1/printers/{id}` | anlegen oder ändern |
| DELETE | `/v1/printers/{id}` | entfernen |
| POST | `/v1/printers/discover` | `{scan?: bool}` → mDNS (3 s) und auf Wunsch Portscan im lokalen /24 |
| POST | `/v1/printers/{id}/test` | Testseite mit den Bytes aus dem Rumpf |
| POST | `/v1/print` | `{printerId, jobId, bytes}` (base64, bis 4 MB) |

`kind` ist `tcp9100` (roher ESC/POS-Strom) oder `epos` (Epson ePOS-Print über
HTTP/HTTPS, `devid` je Gerät; HTTPS gilt allein am Port 443). Gedruckt wird
**seriell je Drucker**, mit 10 s Zeitlimit je Versuch. Wiederholt wird genau
einmal — und **nur, wenn sicher noch nichts hinausgegangen ist** (Verbindung
kam nicht zustande). Sobald Bytes abgeschickt sind, gibt es keinen zweiten
Versuch: ein doppelter Bon wiegt schwerer als ein fehlender, den die Kasse
nachdrucken kann. Derselbe `jobId` druckt auf demselben Drucker innerhalb von
60 Sekunden kein zweites Mal (Schlüssel ist `printerId` + `jobId` — derselbe
Beleg an Kasse und Küche sind zwei Aufträge).

| Code | Bedeutung |
|---|---|
| `printer_unknown` | diese Drucker-ID kennt der Agent nicht |
| `printer_offline` | keine Verbindung zum Gerät |
| `timeout` | keine Bestätigung in der Zeit; mit `detail.mayHavePrinted = true` ist offen, ob der Bon lief |
| `refused` | das Gerät lehnt ab (kein Papier, Deckel offen) |
| `print_in_progress` | derselbe Auftrag läuft gerade noch |
| `internal_error` | der Agent selbst ist gestolpert (steht im Log) |
| `bad_request` | Angaben fehlen oder sind unbrauchbar |

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

### Kasse lokal gegen den Agenten entwickeln

Ansprechen darf den Agenten nur die Kasse selbst:
`https://kasse.kasseneck.at`, `https://kasseneck-kasse.web.app`,
`https://kasseneck-kasse.firebaseapp.com`. Ein lokaler Entwicklungsserver
(`http://localhost:5173`, `http://127.0.0.1:4173`) ist **standardmäßig gesperrt** —
sonst könnte auf einem Kundenrechner jede beliebige lokale Webseite drucken.

Zum Entwickeln freischalten, eines von beiden:

```bash
KASSENECK_CONNECT_DEV=1 kasseneck-connect run     # nur für diesen Lauf
```

oder dauerhaft in der `config.json` des Entwicklungsrechners:

```json
{ "allowDevOrigins": true }
```

Auf Kundenrechnern bleibt beides aus.

Ohne `Origin`-Kopfzeile (curl, Diagnosewerkzeuge) sind nur `GET /v1/status` und
`POST /v1/pair` erreichbar; alles andere verlangt eine erlaubte Herkunft **und**
einen Token.

---

© 2026 Kreiseck – Software Solutions. Alle Rechte vorbehalten.
