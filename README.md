# Kasseneck Connect

Lokaler Agent für die Browser-Kasse von **Kasseneck**. Er läuft als eigenständige
Binary auf dem Kassenrechner, koppelt sich mit der Kasse im Browser und übernimmt
das, was eine Webseite selbst nicht kann: **Netzwerk-Bondrucker finden und die
Beleg-Bytes der Kasse drucken** (TCP 9100 bzw. Epson ePOS).

## Warum es das gibt

Ein Browser darf aus guten Gründen keine rohen TCP-Verbindungen ins lokale Netz
aufmachen. Ein Bondrucker spricht aber genau das: rohe ESC/POS-Bytes auf Port
9100. Connect sitzt als schmale Brücke dazwischen — er lauscht **ausschließlich**
auf `127.0.0.1`, nimmt von der Kasse fertige Bytes entgegen und schickt sie an
den Drucker. Die Kasse erzeugt die ESC/POS-Bytes weiterhin selbst; Connect ist
reiner Transport und kennt weder Belegtexte noch Beträge.

Aus dem LAN ist der Agent nicht erreichbar, ansprechen darf ihn nur die Kasse
selbst (feste Herkunftsliste), und jede Anfrage außer der Statusabfrage braucht
einen Kopplungstoken.

Später kommen das Zahlungsterminal (v1.1) und die Selbstaktualisierung (v1.2)
dazu.

## Installation

Die Kasse verlinkt im Download-Abschnitt immer die **neueste** Fassung unter
diesen festen Adressen (`https://storage.googleapis.com/kasseneck.appspot.com/connect/latest/…`):

| System | Datei |
|---|---|
| macOS, Apple Silicon | `KasseneckConnect-macos-arm64.pkg` |
| macOS, Intel | `KasseneckConnect-macos-x64.pkg` |
| Windows | `KasseneckConnect-windows-x64.exe` |
| Linux (Debian/Ubuntu) | `KasseneckConnect-linux-x64.deb` |

Dieselben Dateien liegen versioniert unter `connect/<version>/` — dort heißen
sie `KasseneckConnect-<version>-<os>-<arch>.<endung>`. **Diese vier Namen sind
verbindlich**: sie stehen in `lib/src/downloads.dart`, `tool/_common.sh` und
`tool/release.sh` und werden von `test/downloads_test.dart` gegeneinander
festgenagelt.

### macOS

1. `KasseneckConnect-macos-arm64.pkg` (Apple Silicon) bzw.
   `KasseneckConnect-macos-x64.pkg` (Intel) herunterladen.
2. Das Paket ist in dieser Fassung **nicht signiert**. Ein Doppelklick bringt
   deshalb „… kann nicht geöffnet werden, da es von einem nicht verifizierten
   Entwickler stammt." So geht es trotzdem:
   - **Rechtsklick** (bzw. Ctrl-Klick) auf die `.pkg`-Datei → **Öffnen** →
     im Hinweisfenster noch einmal **Öffnen**.
   - Führt das nicht zum Ziel:
     **Systemeinstellungen → Datenschutz & Sicherheit** → ganz unten steht
     „„KasseneckConnect…" wurde blockiert" → **Trotzdem öffnen**, danach mit
     Fingerabdruck oder Kennwort bestätigen.
3. Durch den Installationsassistenten klicken. Das Paket legt die Binary unter
   `/usr/local/kasseneck-connect/` ab, verlinkt sie nach
   `/usr/local/bin/kasseneck-connect` (damit `kasseneck-connect doctor` und
   `kasseneck-connect pair` ohne vollen Pfad laufen), richtet den Autostart für
   den gerade angemeldeten Benutzer ein (LaunchAgent) und startet den Agenten
   sofort.
4. Der Agent öffnet beim ersten Start die Kopplungsseite im Browser — siehe
   **Kopplung**.

**Deinstallieren.** macOS-Pakete bringen keinen Deinstallierer mit; dafür gibt
es `tool/pkg/macos/uninstall.sh` (liegt auch im Repo):

```bash
sudo bash uninstall.sh            # Autostart, Binary, Symlink, Paketvermerk
sudo bash uninstall.sh --purge    # zusätzlich Konfiguration und Log
```

Ohne `--purge` bleiben die gekoppelten Kassen und die Drucker erhalten. Von
Hand geht es genauso: `kasseneck-connect uninstall-autostart`, dann
`/usr/local/kasseneck-connect` und `/usr/local/bin/kasseneck-connect` löschen
und `sudo pkgutil --forget at.kasseneck.connect`.

### Windows

1. `KasseneckConnect-windows-x64.exe` herunterladen.
2. Auch dieser Installer ist **nicht signiert**. SmartScreen meldet „Der
   Computer wurde durch Windows geschützt":
   **Weitere Informationen** anklicken → **Trotzdem ausführen**.
3. Installiert wird ohne Administratorrechte nach
   `%LocalAppData%\KasseneckConnect`. Der Installer legt danach die Aufgabe
   „Kasseneck Connect" in der Aufgabenplanung an (Auslöser: bei der Anmeldung)
   und startet den Agenten.

### Linux

Auf Debian und Ubuntu das Paket einspielen — es legt die Binary ab, verlinkt
sie nach `/usr/local/bin/` und richtet den Autostart (systemd --user) für den
aufrufenden Benutzer ein:

```bash
sudo apt install ./KasseneckConnect-linux-x64.deb
```

Das Paket ist **unsigniert**; `apt` meldet das beim Einspielen aus einer Datei
nicht weiter. Entfernen mit `sudo apt remove kasseneck-connect`.

Auf anderen Systemen die nackte Binary aus `connect/<version>/` nehmen:

```bash
chmod +x kasseneck-connect-linux-x64
sudo mv kasseneck-connect-linux-x64 /usr/local/bin/kasseneck-connect
kasseneck-connect install-autostart   # systemd --user
```

## Kopplung

Damit die Kasse mit dem Agenten reden darf, tauschen die beiden einmalig einen
Code gegen einen Token:

1. Der Agent zeigt beim ersten Start einen **sechsstelligen Code** an (Konsole
   und Log) und öffnet `https://kasse.kasseneck.at/connect#code=…&port=…` im
   Standardbrowser. Wurde das Fenster geschlossen, liefert
   `kasseneck-connect pair` jederzeit einen frischen Code samt Adresse.
2. Den Code in der Kasse eingeben. Die Kasse holt sich dafür einen Token, den
   sie ab dann bei jeder Anfrage mitschickt.
3. Der Code ist **10 Minuten** gültig. Nach **5** Fehlversuchen ist die Kopplung
   **60 Sekunden** gesperrt — dann auch für den richtigen Code.

Vom Token speichert der Agent nur den SHA-256-Hash; im Klartext sieht ihn allein
die Kasse. Mehrere Geräte dürfen gekoppelt sein; die Kasse kann ihren eigenen
Token über `DELETE /v1/pair` wieder zurückziehen.

## Befehle

```
kasseneck-connect <befehl>
```

| Befehl | Zweck |
|---|---|
| `run` | Agent starten (lokale API auf `127.0.0.1:27182`, Fallback 27183–27189) |
| `pair` | Kopplungscode für die Kasse anzeigen |
| `install-autostart` | Autostart einrichten und Agenten starten |
| `uninstall-autostart` | Autostart entfernen und Agenten anhalten |
| `doctor` | Diagnose ausgeben (Version, Pfade, Ports, Drucker, Fehler) |
| `version` | Version ausgeben |

`run` läuft, bis SIGINT/SIGTERM kommt. Ist noch kein Gerät gekoppelt, erzeugt der
Start einen Code und öffnet die Kopplungsseite;
`KASSENECK_CONNECT_NO_BROWSER=1` unterdrückt das Öffnen. `pair` läuft auch
**neben** dem Agenten — beide teilen sich den Zustand in der `config.json`.

Was `install-autostart` je System anlegt:

| System | Eintrag |
|---|---|
| macOS | `~/Library/LaunchAgents/at.kasseneck.connect.plist` (`RunAtLoad`, `KeepAlive`), geladen mit `launchctl bootstrap gui/<uid>` |
| Windows | Aufgabenplanung „Kasseneck Connect", Auslöser „Bei Anmeldung", `/RL LIMITED` |
| Linux | `~/.config/systemd/user/kasseneck-connect.service`, `systemctl --user enable --now` |

Der Eintrag verweist immer auf die Binary, die den Befehl ausgeführt hat
(`Platform.resolvedExecutable`) — der Agent trägt also sich selbst ein.

## Konfigurationspfade

Konfiguration und Log liegen im Datenverzeichnis des Agenten:

| System | Verzeichnis |
|---|---|
| macOS | `~/Library/Application Support/KasseneckConnect` |
| Windows | `%ProgramData%\KasseneckConnect` |
| Linux | `$XDG_CONFIG_HOME/kasseneck-connect`, sonst `~/.config/kasseneck-connect` |

Darin: `config.json` (Port, Token-Hashes, Drucker, Terminal, Update-Kanal; atomar
geschrieben, Rechte 600) und `logs/connect.log` (täglich rotierend, 7 Dateien).
Auf macOS liegen daneben `logs/launchd.out.log` und `logs/launchd.err.log` —
dorthin schreibt der LaunchAgent, wenn der Agent so früh stirbt, dass er sein
eigenes Log nicht mehr erreicht. Die Umgebungsvariable
`KASSENECK_CONNECT_HOME` überschreibt das Verzeichnis.

Gepflegt wird die Konfiguration ausschließlich über die lokale API aus der Kasse
heraus — Handarbeit in der Datei ist nicht nötig.

## API-Kurzreferenz

Basis: `http://127.0.0.1:27182` (bei belegtem Port bis 27189 hinauf; die Kasse
probiert die Reihe durch und erkennt den Agenten an `GET /v1/status`).

Alle Pfade außer `GET /v1/status` und `POST /v1/pair` brauchen den
Kopplungstoken (`Authorization: Bearer …`) **und** eine erlaubte Herkunft.
Fachfehler kommen mit **HTTP 200** und `{ok: false, error: {code, message}}`;
eigene HTTP-Codes gibt es nur für 401 (Token fehlt/falsch), 403 (fremde
Herkunft), 404 (Pfad unbekannt) und 413 (Rumpf zu groß).

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/v1/status` | Lebenszeichen; ohne Token Kurzform, mit Token zusätzlich Drucker und letzte Fehler |
| POST | `/v1/pair` | `{code}` → `{token}` |
| DELETE | `/v1/pair` | den mitgeschickten Token zurückziehen |
| GET | `/v1/printers` | konfigurierte Drucker samt Zustand (`?probe=0` fragt die Geräte nicht an) |
| PUT | `/v1/printers` | anlegen — `{name, kind, host, port?, devid?}`, die ID vergibt der Agent |
| PUT | `/v1/printers/neu` | dasselbe für Kassen, die im Pfad eine ID brauchen |
| PUT | `/v1/printers/{id}` | anlegen oder ändern |
| DELETE | `/v1/printers/{id}` | entfernen |
| POST | `/v1/printers/discover` | `{scan?: bool}` → mDNS (3 s) und auf Wunsch Portscan aller lokalen /24 |
| POST | `/v1/printers/{id}/test` | Testseite mit den Bytes aus dem Rumpf |
| POST | `/v1/print` | `{printerId, jobId, bytes}` (base64, bis 4 MB) |
| WS | `/v1/events` | Ereignisstrom (siehe unten) |

Beim Anlegen (`PUT /v1/printers` oder `PUT /v1/printers/neu`) vergibt der Agent
die ID — die Kasse denkt sich keine aus. Zeigt dabei schon ein Drucker auf
dieselbe Adresse (`host:port`), wird **dieser** aktualisiert statt ein zweiter
angelegt: sonst hätte ein zweiter Einrichtungsdurchgang jeden Bon verdoppelt.
Wer wirklich zwei Einträge auf eine Adresse will, gibt eine ID im Pfad an.

`POST /v1/printers/discover` antwortet mit `{ok, printers, scanned}`. In
`scanned` steht je abgesuchtem Netz `{interface, subnet, hosts}` — damit kann
die Kasse „Suche in 192.168.0.0/24 …" anzeigen und beim Kunden lässt sich
sehen, ob überhaupt im richtigen Netz gesucht wurde. Gescannt werden **alle**
IPv4-Netze des Rechners (höchstens vier, ohne 169.254.x, ein Netz je /24), je
Adresse 300 ms, insgesamt höchstens 8 s. Nur das erste Netz zu nehmen ging
schief: auf Rechnern mit Parallels, Docker oder VPN steht das WLAN nicht
zwingend vorn, und im Netz einer virtuellen Maschine hängt kein Drucker. Zum
Nachsehen auf einem fremden Rechner: `dart run tool/scan_debug.dart`.

`kind` ist `tcp9100` (roher ESC/POS-Strom) oder `epos` (Epson ePOS-Print über
HTTP/HTTPS, `devid` je Gerät; HTTPS gilt allein am Port 443). Gedruckt wird
**seriell je Drucker**, mit 10 s Zeitlimit je Versuch. Wiederholt wird genau
einmal — und **nur, wenn sicher noch nichts hinausgegangen ist** (Verbindung
kam nicht zustande). Sobald Bytes abgeschickt sind, gibt es keinen zweiten
Versuch: ein doppelter Bon wiegt schwerer als ein fehlender, den die Kasse
nachdrucken kann. Derselbe `jobId` druckt auf demselben Drucker innerhalb von
60 Sekunden kein zweites Mal (Schlüssel ist `printerId` + `jobId` — derselbe
Beleg an Kasse und Küche sind zwei Aufträge).

### Ereignisse (`GET /v1/events`, WebSocket)

```js
const ws = new WebSocket(`ws://127.0.0.1:27182/v1/events?token=${token}`);
```

Der Browser kann bei `new WebSocket(url)` keine Kopfzeilen setzen — deshalb
nimmt **allein diese Route** den Token auch als Query-Parameter `?token=…`
entgegen (mit `Authorization: Bearer …` geht es ebenso, z. B. aus einem
Skript). An jeder anderen Route bleibt der Query-Parameter wirkungslos, und
ohne gültigen Token kommt es gar nicht erst zum Upgrade — der Klient sieht eine
401 statt eines offenen Sockets.

Sofort nach dem Verbinden kommt die Begrüßung, danach jedes Ereignis als eine
JSON-Zeile; alle 30 Sekunden geht ein Ping hinaus, damit tote Verbindungen
auffallen.

```json
{"type": "hello", "version": "0.1.0", "port": 27182}
{"type": "printer.state", "printerId": "p_ab12cd34", "state": "online"}
{"type": "print.done",    "printerId": "p_ab12cd34", "jobId": "beleg-42", "attempts": 1}
{"type": "print.failed",  "printerId": "p_ab12cd34", "jobId": "beleg-43", "code": "printer_offline", "message": "…"}
```

Der Strom hat **keinen Puffer**: wer nicht zuhört, verpasst das Ereignis. Der
belastbare Zustand steht in `GET /v1/status`; die Ereignisse sind nur die
schnelle Benachrichtigung obendrauf.

### Fehlercodes

| Code | Bedeutung |
|---|---|
| `origin_forbidden` | diese Herkunft darf den Agenten nicht ansprechen (HTTP 403) |
| `unauthorized` | Token fehlt oder ist ungültig (HTTP 401) |
| `not_found` | diesen Pfad gibt es nicht (HTTP 404) |
| `bad_request` | Angaben fehlen oder sind unbrauchbar |
| `body_too_large` | Rumpf über der Grenze (HTTP 413) |
| `pair_invalid` | Kopplungscode stimmt nicht |
| `pair_expired` | Kopplungscode ist abgelaufen |
| `pair_locked` | zu viele Fehlversuche, 60 s Sperre |
| `printer_unknown` | diese Drucker-ID kennt der Agent nicht |
| `printer_offline` | keine Verbindung zum Gerät |
| `timeout` | keine Bestätigung in der Zeit; mit `detail.mayHavePrinted = true` ist offen, ob der Bon lief |
| `refused` | das Gerät lehnt ab (kein Papier, Deckel offen) |
| `print_in_progress` | derselbe Auftrag läuft gerade noch |
| `internal_error` | der Agent selbst ist gestolpert (steht im Log) |

## Fehlersuche

```bash
kasseneck-connect doctor
```

Die Diagnose nennt Version, Programmpfad, Konfigurations- und Logpfad, ob
gekoppelt ist, auf welchem der Ports 27182–27189 ein Agent antwortet, die
eingetragenen Drucker mit ihrem aktuellen Zustand, den Autostart-Zustand und die
letzten Fehlerzeilen aus dem Log.

| Symptom | Nächster Schritt |
|---|---|
| „Kein Agent erreichbar" | Läuft er? `kasseneck-connect run` im Terminal starten und die Ausgabe lesen |
| Kasse findet den Agenten nicht | `doctor` zeigt den tatsächlichen Port; Firewall auf der Loopback-Adresse prüfen |
| Kasse meldet „nicht gekoppelt" | `kasseneck-connect pair` und den Code neu eingeben |
| Drucker `offline` | IP und Port prüfen (`doctor`), Gerät anpingen, `POST /v1/printers/discover` |
| Bon kam nicht | Log ansehen: `logs/connect.log`; bei `timeout` mit `mayHavePrinted` erst am Gerät nachsehen |
| Agent startet nach dem Neustart nicht | `doctor` → Autostart-Zeile; notfalls `install-autostart` erneut |

Ins Log kommen **keine Beleginhalte** — nur IDs, Fehlercodes und Klartext.
Die Datei darf deshalb bedenkenlos an den Support gehen.

## Entwicklung

```bash
dart pub get
dart test
dart analyze
dart format .
```

Bauen:

```bash
tool/build_macos.sh              # -> build/kasseneck-connect-macos-<arch>
tool/pkg/macos/build_pkg.sh      # -> build/KasseneckConnect-<version>-macos-<arch>.pkg
tool/build_linux.sh              # -> build/kasseneck-connect-linux-<arch>
tool/build_linux_deb.sh          # -> build/KasseneckConnect-<version>-linux-<arch>.deb
powershell -File tool\build_windows.ps1   # Binary + (mit Inno Setup) Installer
```

`tool/_common.sh` hält die Namensregel und die Architekturnormalisierung
(`x86_64`/`amd64` → `x64`, `aarch64` → `arm64`) an einer Stelle; alle
Build-Skripte laden sie. `build_linux_deb.sh` braucht `dpkg-deb` und
überspringt sich mit einem Hinweis, wo es das nicht gibt (z. B. auf einem Mac)
— das echte `.deb` entsteht in der CI auf ubuntu.

Veröffentlichen in den Update-Feed (von Hand, braucht eine angemeldete
`gcloud`):

```bash
tool/release.sh --dry-run        # zeigt latest.json und alle Uploads
tool/release.sh                  # lädt build/* nach gs://kasseneck.appspot.com/connect/
```

Die CI (`.github/workflows/ci.yml`) fährt bei jedem Push und jedem Pull Request
`dart format --set-exit-if-changed`, `dart analyze --fatal-infos` und
`dart test`, danach die Build-Matrix (macOS arm64/x64, Windows, Linux) und legt
die Ergebnisse als Artefakte ab. In den Storage lädt die CI **nichts** — das
bleibt `tool/release.sh` von Hand vorbehalten.

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
