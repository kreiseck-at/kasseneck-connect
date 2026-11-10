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

Ab 1.3 ist Connect am Mac zusätzlich eine **Bluetooth-Brücke**: die Kasse
erreicht zugelassene Bluetooth-Geräte (zuerst den Etikettendrucker) über die
lokale API statt über Web Bluetooth, auch in Safari. Die Bytes erzeugt weiter
die Kasse; Connect verbindet, schreibt, hält Abos und gibt das Gerät nach
kurzer Pause wieder frei (siehe **Bluetooth-Brücke**).

## Installation

Die Kasse verlinkt im Download-Abschnitt immer die **neueste** Fassung als
GitHub-Release dieses Repos — Adressen der Form
`https://github.com/kreiseck-at/kasseneck-connect/releases/latest/download/<name>`:

| System | Datei |
|---|---|
| macOS, Apple Silicon | [`KasseneckConnect-macos-arm64.pkg`](https://github.com/kreiseck-at/kasseneck-connect/releases/latest/download/KasseneckConnect-macos-arm64.pkg) |
| macOS, Intel | [`KasseneckConnect-macos-x64.pkg`](https://github.com/kreiseck-at/kasseneck-connect/releases/latest/download/KasseneckConnect-macos-x64.pkg) |
| Windows | [`KasseneckConnect-windows-x64.exe`](https://github.com/kreiseck-at/kasseneck-connect/releases/latest/download/KasseneckConnect-windows-x64.exe) |
| Linux (Debian/Ubuntu) | [`KasseneckConnect-linux-x64.deb`](https://github.com/kreiseck-at/kasseneck-connect/releases/latest/download/KasseneckConnect-linux-x64.deb) |

`releases/latest/download/…` löst GitHub selbst immer auf das jeweils neueste
Release auf — die Adresse bleibt über Versionen hinweg stabil. Dieselben
Dateien liegen zusätzlich versioniert im jeweiligen Release `v<version>`, dort
heißen sie `KasseneckConnect-<version>-<os>-<arch>.<endung>`. **Diese vier
Namen sind verbindlich**: sie stehen in `lib/src/downloads.dart`,
`tool/_common.sh` und `tool/release.sh` und werden von
`test/downloads_test.dart` gegeneinander festgenagelt.

Warum GitHub Releases statt des Firebase-Storage-Buckets: der Bucket hält
Kundendaten und darf deshalb nicht öffentlich lesbar sein. Dieses Repo ist
öffentlich — ein GitHub-Release liefert damit kostenlos stabile, direkt
verlinkbare Download-Adressen, ohne dass irgendwo ein Bucket-Präfix
freigeschaltet werden müsste.

### macOS

1. `KasseneckConnect-macos-arm64.pkg` (Apple Silicon) bzw.
   `KasseneckConnect-macos-x64.pkg` (Intel) herunterladen.
2. Doppelklicken. **Ab 1.0.2 ist das Paket signiert und notarisiert**
   (Herausgeber „POST NOW e.U.“) — der Umweg über die Systemeinstellungen
   entfällt, macOS öffnet es ohne Nachfrage.

   <details><summary>Ältere Fassungen (bis 1.0.1) waren unsigniert</summary>

   Dort blockt macOS mit „Apple could not verify …“; seit macOS 15 (Sequoia)
   hilft auch Rechtsklick → Öffnen nicht mehr:
   - Dialog mit **Fertig** schließen (nicht „In den Papierkorb legen“), dann
     **Systemeinstellungen → Datenschutz & Sicherheit** → ganz unten steht
     „„KasseneckConnect…“ wurde blockiert“ → **Dennoch öffnen**, danach mit
     Fingerabdruck oder Kennwort bestätigen.
   - Alternative im Terminal (entfernt die Quarantäne-Markierung des
     Downloads): `xattr -d com.apple.quarantine ~/Downloads/KasseneckConnect-macos-arm64.pkg`

   </details>
3. Durch den Installationsassistenten klicken. Das Paket legt das App-Paket
   `Kasseneck Connect.app` unter `/usr/local/kasseneck-connect/` ab (darin die
   Binary des Agenten und das Bluetooth-Hilfsprogramm; kein Dock-Symbol),
   verlinkt die Binary nach `/usr/local/bin/kasseneck-connect` (damit
   `kasseneck-connect doctor` und `kasseneck-connect pair` ohne vollen Pfad
   laufen), richtet den Autostart für den gerade angemeldeten Benutzer ein
   (LaunchAgent auf die Binary im App-Paket) und startet den Agenten sofort.
4. Gegen Ende fragt macOS einmal nach Kennwort oder Touch ID (Absender
   „security“): damit vertraut der Mac der lokalen Zertifizierungsstelle für
   den HTTPS-Zugang, den Safari braucht (siehe **API-Kurzreferenz**). Wer
   abbricht oder ohne angemeldeten Benutzer installiert, holt das im Terminal
   nach: `kasseneck-connect zertifikat-vertrauen`. Beim ersten Update von 1.2.x
   fragt macOS einmal; bei späteren Updates ist die Stelle schon vertraut.
5. Der Agent öffnet beim ersten Start die Kopplungsseite im Browser — siehe
   **Kopplung**.
6. Die Bluetooth-Freigabe fragt macOS erst, wenn die Kasse zum ersten Mal ein
   Bluetooth-Gerät sucht oder anspricht, nicht bei der Installation. Der
   Dialog nennt „Kasseneck Connect“, zeigt das Symbol und den Text
   „Kasseneck Connect verbindet die Kasse mit Bluetooth-Druckern wie dem
   Etikettendrucker.“ Danach steht „Kasseneck Connect“ unter
   **Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth**.
7. Ab macOS 15 fragt macOS beim ersten Zugriff auf Drucker oder
   Kartenterminal nach dem **lokalen Netzwerk** („Kasseneck Connect verbindet
   die Kasse mit Bondruckern und dem Kartenterminal im lokalen Netzwerk.“).
   Erlauben. Solange der Dialog offen ist, kann der erste Versuch schon
   scheitern – danach einfach wiederholen. Die Freigabe steht unter
   **Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk**.
   Fehlt sie, scheitert jede Verbindung mit „No route to host“; die Meldung an
   die Kasse nennt dann diesen Weg.

Ein Update von 1.2.x über das neue Paket behält Konfiguration, gekoppelte
Kassen und Drucker; der Autostart zeigt danach auf die Binary im App-Paket.

**Deinstallieren.** macOS-Pakete bringen keinen Deinstallierer mit; dafür gibt
es `tool/pkg/macos/uninstall.sh` (liegt auch im Repo):

```bash
sudo bash uninstall.sh            # Autostart, Vertrauen (HTTPS), Bluetooth-Freigabe, App-Paket, Symlink, Paketvermerk
sudo bash uninstall.sh --purge    # zusätzlich Konfiguration, Zertifikate und Log
```

Das Skript hält den Agenten an, nimmt den LaunchAgent heraus, entzieht der
lokalen Zertifizierungsstelle das Vertrauen (macOS fragt dabei nach Kennwort
oder Touch ID) und prüft danach nach. Aus dem Anmelde-Schlüsselbund löscht es
sie nur mit Beleg, dass ihr nicht mehr vertraut wird: das Serverzertifikat ist
gültig, die Prüfung wie im Agenten scheitert, und die Vertrauenseinstellungen
des Benutzers kennen sie nicht. Sonst bleibt sie stehen, und das Skript warnt
und nennt den Befehl, mit dem man das Vertrauen selbst entzieht. Dann setzt es
die Bluetooth-Freigabe von „Kasseneck Connect“ zurück und löscht
`/usr/local/kasseneck-connect` samt App-Paket. Ohne `--purge` bleiben die
gekoppelten Kassen, die Drucker und die Zertifikatsdateien erhalten. Mit
`--purge` geht die Konfiguration weg; fehlt der Beleg, bleibt nur
`tls/ca-cert.pem` stehen, weil der genannte Befehl sie braucht – den Ordner
danach von Hand löschen. Von
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
4. Im selben Ordner liegen auch `config.json` und `logs\` — alles gehört dem
   angemeldeten Benutzer. Beim Deinstallieren nimmt Windows nur die
   Programmdateien mit; Kopplung und Drucker bleiben stehen, bis der Ordner von
   Hand gelöscht wird.

Ein Update (dieselbe `.exe` über eine vorhandene Installation) beendet zuerst
den laufenden Agenten — sonst hielte er seine eigene Datei gesperrt — und
richtet den Autostart danach neu ein.

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
   `kasseneck-connect pair` jederzeit einen frischen Code samt Adresse — und
   die Kasse kann dasselbe selbst anstoßen (`POST /v1/pair/request`, ohne
   Token, höchstens einmal je 10 Sekunden). Der Code kommt dabei **nicht** über
   die API zurück; er steht allein in dem lokal geöffneten Fenster.
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
| `zertifikat-vertrauen` | der lokalen Zertifizierungsstelle für HTTPS vertrauen (nur Mac; macOS fragt einmal nach Kennwort oder Touch ID) |
| `betrieb-abwarten` | warten, bis kein Druck und keine Zahlung läuft (höchstens 5 min; das postinstall eines Updates ruft ihn vor dem Neustart) |
| `doctor` | Diagnose ausgeben (Version, Pfade, Ports, HTTPS, Bluetooth, Drucker, abgeschaltete Neuerungen, Fehler) |
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
(`Platform.resolvedExecutable`) — der Agent trägt also sich selbst ein. Am Mac
ist das die Binary im App-Paket
(`/usr/local/kasseneck-connect/Kasseneck Connect.app/Contents/MacOS/kasseneck-connect`),
auch wenn der Befehl über einen Symlink lief: macOS ordnet die
Bluetooth-Freigabe dem Paket zu.

## Konfigurationspfade

Konfiguration und Log liegen im Datenverzeichnis des Agenten:

| System | Verzeichnis |
|---|---|
| macOS | `~/Library/Application Support/KasseneckConnect` |
| Windows | `%LocalAppData%\KasseneckConnect` |
| Linux | `$XDG_CONFIG_HOME/kasseneck-connect`, sonst `~/.config/kasseneck-connect` |

Unter Windows liegt alles beim angemeldeten Benutzer, im selben Ordner, in den
auch das Paket installiert — dort darf der Agent ohne Administratorrechte
schreiben. Nur wenn `LOCALAPPDATA` gar nicht gesetzt ist (Dienstkonten), weicht
er auf `%ProgramData%\KasseneckConnect` aus.

Darin: `config.json` (Port, Token-Hashes, Drucker, Terminal, Update-Kanal; atomar
geschrieben, Rechte 600) und `logs/connect.log` (täglich rotierend, 7 Dateien).
Neben der `config.json` liegt `config.json.bak`, die Fassung vor dem letzten
Speichern. Ist die `config.json` einmal unbrauchbar (kein JSON, leer, nicht
lesbar), legt Connect sie unverändert als `config.json.defekt-<UTC-Zeitstempel>`
ab, meldet das als Fehler im Log und arbeitet mit `config.json.bak` weiter;
erst ohne brauchbare Sicherung startet er ohne Kopplungen und Drucker. Die
kaputte Datei ersetzt erst das nächste Speichern – nachdem sie aufbewahrt ist.
Wer die `config.json` zum Zurücksetzen löscht, muss `config.json.bak`
mitlöschen.
Auf macOS liegen daneben `logs/launchd.out.log` und `logs/launchd.err.log` —
dorthin schreibt der LaunchAgent, wenn der Agent so früh stirbt, dass er sein
eigenes Log nicht mehr erreicht. Die Umgebungsvariable
`KASSENECK_CONNECT_HOME` überschreibt das Verzeichnis.

Gepflegt wird die Konfiguration ausschließlich über die lokale API aus der Kasse
heraus — Handarbeit in der Datei ist nicht nötig.

## API-Kurzreferenz

Basis: `http://127.0.0.1:27182` (bei belegtem Port bis 27189 hinauf; die Kasse
probiert die Reihe durch und erkennt den Agenten an `GET /v1/status`).

Am Mac lauscht derselbe Agent zusätzlich über **HTTPS** auf
`https://127.0.0.1:27190` (Ausweich bis 27197) — Safari lässt eine Seite unter
`https://` nicht an `http://127.0.0.1`. Herkunft, Token und Pfade sind dieselben.
Das Zertifikat stammt von einer eigenen Zertifizierungsstelle je Rechner
(„Kasseneck Connect (lokal)“, nur gültig für `127.0.0.1` und `localhost`), der
der Installer einmal vertraut; das Serverzertifikat erneuert der Agent selbst.
Vertraut wird einmal je Rechner und Benutzer: im Installer oder später mit
`kasseneck-connect zertifikat-vertrauen`. macOS fragt dabei nach Kennwort oder
Touch ID, als Absender steht „security“ im Dialog. Der Agent selbst fragt nie;
fehlt das Vertrauen, steht das in `GET /v1/status` (`tls.trusted`) und in
`doctor`. `GET /v1/status` meldet `port` und `httpsPort`; `features` enthält
`https`, solange der Zugang lauscht.

Alle Pfade außer `GET /v1/status`, `POST /v1/pair` und `POST /v1/pair/request`
brauchen den Kopplungstoken (`Authorization: Bearer …`) **und** eine erlaubte
Herkunft.
Fachfehler kommen mit **HTTP 200** und `{ok: false, error: {code, message}}`;
eigene HTTP-Codes gibt es nur für 401 (Token fehlt/falsch), 403 (fremde
Herkunft), 404 (Pfad unbekannt), 413 (Rumpf zu groß) und 426 (`/v1/events` ohne
WebSocket-Upgrade).

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/v1/status` | Lebenszeichen; ohne Token Kurzform, mit Token zusätzlich Drucker, letzte Fehler und (HTTPS) `tls: {notAfter, trusted}` |
| POST | `/v1/pair` | `{code}` → `{token}` |
| POST | `/v1/pair/request` | Kopplung anstoßen: neuer Code, Kopplungsseite geht lokal im Browser auf → `{ok}` (nie der Code) |
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
| GET | `/v1/update` | `{current, latest, available, platform, size, oneClick, progress, lastError}` – neueste Version aus `latest.json` (höchstens alle 6 h abgerufen, wartet nie länger als ~1 s); `progress` (`{version, phase, percent}`) und `lastError` (`{version, code, message}`) zum Abfragen statt Zuhören |
| POST | `/v1/update` | Aktualisieren auf einen Klick (nur macOS, `oneClick`): lädt, prüft und öffnet den Installer → `{started: true}`, Fortschritt als Ereignis |
| POST | `/v1/printers/{id}/status` | ab 1.5.0: Papier, Deckel und Erreichbarkeit sofort abfragen (über die Warteschlange) → `{printer}` |
| POST | `/v1/printers/{id}/locate` | ab 1.5.0: Drucker gründlich unter neuer Adresse suchen → `{relocated, from, to, printer}` oder `device_not_found` |
| GET | `/v1/diagnosis` | ab 1.5.0: Diagnose für den Support nach Positivliste (`?lines=200`, höchstens 500) |
| POST | `/v1/restart` | ab 1.5.0, nur mit Fähigkeit `restart`: Connect beenden, der Autostart startet ihn neu → `{restarting: true}` |

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
Beleg an Kasse und Küche sind zwei Aufträge). Gemerkt wird dabei nur, was ein
zweiter Druck verschlimmern könnte: der gelungene Druck und der Fehler mit
offenem Ausgang (`detail.mayHavePrinted`). Ist ein Auftrag **sauber**
gescheitert — kein Papier, Drucker aus, nichts hinausgegangen —, druckt
dieselbe `jobId` sofort wieder, sobald die Ursache behoben ist.

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
{"type": "hello", "version": "1.0.0", "port": 27182}
{"type": "printer.state", "printerId": "p_ab12cd34", "state": "online"}
{"type": "print.done",    "printerId": "p_ab12cd34", "jobId": "beleg-42", "attempts": 1}
{"type": "print.failed",  "printerId": "p_ab12cd34", "jobId": "beleg-43", "code": "printer_offline", "message": "…"}
```

Bei einer Aktualisierung (`POST /v1/update`) kommen dazu `update.progress`
(`{version, phase: download|check|waiting|ready, percent}`; `waiting` ab 1.5.0:
ein Druck oder eine Zahlung läuft, der Installer öffnet danach), `update.failed`
(`{version, code, message}`) und – unmittelbar bevor sich der Installer öffnet –
`agent.restarting` (`{reason: "update", version}`): Der Installer beendet und
startet Connect neu, die Verbindung ist danach kurz weg.

Ab 1.5.0 trägt `printer.state` zusätzlich `paper`, `cover` und `statusAt`,
sobald der Drucker sie gemeldet hat, und kommt auch bei einer Änderung von
Papier oder Deckel. Neu sind `printer.relocated` (`{printerId, from, to}`) und
`terminal.relocated` (`{tid, from, to}`) – nur für Log und Diagnose, die Kasse
zeigt sie nicht. Vor `POST /v1/restart` kommt `agent.restarting`
(`{reason: "restart"}`).

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
| `upgrade_required` | `/v1/events` wurde ohne WebSocket-Upgrade aufgerufen (HTTP 426) |
| `pair_invalid` | Kopplungscode stimmt nicht |
| `pair_expired` | Kopplungscode ist abgelaufen |
| `pair_locked` | zu viele Fehlversuche, 60 s Sperre |
| `printer_unknown` | diese Drucker-ID kennt der Agent nicht |
| `printer_offline` | keine Verbindung zum Gerät |
| `update_unsupported` | auf diesem System gibt es den Ein-Klick nicht (nur Download) |
| `update_not_available` | es gibt keine neuere Version |
| `update_busy` | eine Aktualisierung läuft bereits |
| `update_download_failed` | das Paket ließ sich nicht laden (Ereignis) |
| `update_checksum_mismatch` | Größe oder SHA-256 stimmen nicht mit `latest.json` (Ereignis) |
| `update_signature_invalid` | keine gültige, notarisierte Signatur von Post Now e.U. (Ereignis) |
| `update_not_newer` | das geladene Paket ist nicht neuer (Ereignis) |
| `update_open_failed` | der Installer ließ sich nicht öffnen (Ereignis) |
| `timeout` | keine Bestätigung in der Zeit; mit `detail.mayHavePrinted = true` ist offen, ob der Bon lief |
| `refused` | das Gerät lehnt ab (kein Papier, Deckel offen) |
| `print_in_progress` | derselbe Auftrag läuft gerade noch |
| `paper_out` | ab 1.5.0: Papierende vor dem Druck gemeldet – **kein Byte gesendet**, derselbe Auftrag geht nach dem Einlegen |
| `cover_open` | ab 1.5.0: Deckel offen vor dem Druck – kein Byte gesendet |
| `printer_not_ready` | ab 1.5.0: ein Drucker, der sonst auf `DLE EOT` antwortet, schweigt (Deckel offen, Papier heraus) – kein Byte gesendet |
| `device_not_found` | ab 1.5.0: `locate` ohne eindeutigen Treffer |
| `update_device_busy` | ab 1.5.0: ein Druck oder eine Zahlung läuft – danach aktualisieren (HTTP 409) |
| `restart_busy` | ab 1.5.0: ein Druck oder eine Zahlung läuft (HTTP 409) |
| `terminal_busy` | ab 1.5.0: Connect hält gerade einen langen Aufruf für dieses Terminal (siehe Kartenterminal) |
| `internal_error` | der Agent selbst ist gestolpert (steht im Log) |

Bei Druckfehlern steht in `detail.reason` zusätzlich, was das Gerät gemeldet hat
(ePOS-Statuscode, Socket-Meldung) — dieselbe Angabe wie in der Logzeile, damit
Kasse und Support nicht raten müssen. Beleginhalte stehen dort nie.

### Kartenterminal (Hobex HPS)

Die Kasse spricht das Hobex-Terminal über Connect an (JSON-REST auf Port 8080
im Kassen-Netz); Host, Port und TID schickt sie bei jedem Aufruf mit. Connect
reicht die Antwort des Terminals unverändert als `hps` durch – eine abgelehnte
Zahlung ist `ok: true` mit `responseCode != "0"`, kein Fehler.

| Methode | Pfad | Zweck |
|---|---|---|
| POST | `/v1/terminal/test` | `{host, port?, tid?}` – Erreichbarkeit; ohne TID die nebenwirkungsfreie Probe |
| POST | `/v1/terminal/discover` | `{}` – Terminals im Kassen-Netz suchen |
| POST | `/v1/terminal/diagnosis` | `{host, port?, tid}` |
| POST | `/v1/terminal/payment` | `{host, port?, tid, amountCents, transactionId, tipCents?, reference?, currency?, language?}` – blockiert bis zum Ende des Kartenflows (Antwortfrist 4 min) |
| POST | `/v1/terminal/refund` | `{host, port?, tid, amountCents, transactionId, originalTransactionId, reference?, currency?, language?}` – Gutschrift, ebenfalls ein Kartenfluss |
| POST | `/v1/terminal/status` | `{host, port?, tid, transactionId}` – Stand einer Transaktion |
| POST | `/v1/terminal/abort` | `{host, port?, tid, transactionId}` – Abbruch, solange keine Karte durchgezogen ist |
| POST | `/v1/terminal/cancel` | `{host, port?, tid, transactionId, amountCents, currency?, language?}` – Aufhebung einer Zahlung |
| POST | `/v1/terminal/locate` | ab 1.5.0: `{tid}` – Terminal dieser TID im Netz suchen und merken → `{tid, host, port, relocated, from?}` oder `device_not_found` |

Transportfehler und was sie über den Ausgang sagen:

| Code | Bedeutung |
|---|---|
| `terminal_unreachable` | keine Verbindung zum Terminal (abgelehnt, keine Route oder kein Aufbau in 10 s) – **nachweislich nichts gesendet**, ein neuer Versuch ist gefahrlos |
| `terminal_offline` | die Verbindung stand und ist abgerissen – Ausgang offen |
| `timeout` | das Terminal hat nicht rechtzeitig geantwortet – Ausgang offen |
| `terminal_error` | das Terminal meldet einen Fehler oder antwortet nicht im HPS-Format; nennt es einen HTTP-Status, steht er in `detail.terminalHttpStatus` (`409` = beschäftigt, nichts belastet) |

Der Verbindungsaufbau hat bei jedem Aufruf höchstens 10 Sekunden, auch bei
Zahlung und Gutschrift; deren lange Frist gilt erst für die Antwort. Zahlung
und Gutschrift wiederholt Connect nie von selbst. Bis 1.4.1 kam auch ohne
Verbindung `terminal_offline` – eine Kasse, die beide Fassungen bedient, liest
nur `terminal_unreachable` als „nichts gesendet“.

Nach dem ersten erfolgreichen Kontakt hält Connect das Terminal wach (alle
45 s ein TCP-Verbindungsaufbau ohne Daten), damit sein WLAN nicht einschläft;
das Ziel steht in der `config.json` und gilt auch nach einem Neustart.

Ab 1.5.0:

- Zahlung, Gutschrift und Aufhebung **belegen** das Terminal. Ein zweiter
  solcher Aufruf, eine Diagnose, ein Test oder eine Suche – aus welcher Kasse
  oder welchem Tab auch immer – bekommt sofort `terminal_busy` mit
  `detail.terminalHttpStatus = 409`: nachweislich nichts gesendet, wie wenn das
  Terminal selbst „beschäftigt“ meldet (ältere Kassen lesen es genau so).
  Statusabfrage und Abbruch bleiben frei – sie gelten der laufenden Zahlung.
- Der Wachhalter merkt sich die TID und wann eine Antwort des Terminals sie
  unter dieser Adresse bestätigt hat. Kommt bei einem Aufruf keine Verbindung
  zustande (`terminal_unreachable`) und kennt Connect für diese TID eine
  andere, höchstens 24 h alt bestätigte Adresse, läuft **derselbe Aufruf dort
  genau einmal** – auch Zahlung und Gutschrift, denn der erste Versuch hat
  nachweislich nichts gesendet. Nach `terminal_offline` oder `timeout` nie.
- Jede Antwort der Terminal-Routen trägt `endpoint: {host, port, relocated}`,
  die tatsächlich benutzte Adresse.
- Antwortet das Terminal dreimal hintereinander nicht auf die
  Wachhalte-Berührung, sucht Connect es im Hintergrund (Suche, dann Diagnose
  mit der TID je Treffer; höchstens alle 5 min, nie während einer Zahlung) und
  übernimmt nur genau einen bestätigten Treffer.

### Bluetooth-Brücke (macOS)

Nur am Mac und nur mit dem Hilfsprogramm im App-Paket (zum Entwickeln ohne
Paket zeigt `KASSENECK_CONNECT_BT_HELPER` auf ein anderes); dann enthält
`features` in `GET /v1/status` den Eintrag `bluetooth`. Woran die Kasse die Brücke
erkennt, ist diese Fähigkeit, nicht die Versionsnummer. Ohne Brücke antwortet
jeder Pfad unter `/v1/bluetooth` mit `bluetooth_unsupported`. Es gelten
dieselben Regeln wie überall: Token, erlaubte Herkunft, Fehlerhülle mit
HTTP 200.

Das Hilfsprogramm (`kasseneck-bluetooth`, Swift, CoreBluetooth) startet der
Agent erst beim ersten Bluetooth-Aufruf als Kindprozess, nie beim Start, und
startet es nach Absturz oder Hänger neu. Ein Gerät ist erst nutzbar, wenn die
Kasse es zugelassen hat (höchstens 16; Kennung, Name und Zeitpunkt stehen in
der `config.json`). Dienste der Web-Bluetooth-Sperrliste (u. a. HID, FIDO) und
Firmware-Update-Dienste bleiben immer gesperrt.

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/v1/bluetooth` | Zustand und zugelassene Geräte mit Verbindungsstand; startet Bluetooth nie und wartet nie auf einen Neustart (ein laufendes Hilfsprogramm ohne Freigabe wird gedrosselt im Hintergrund ersetzt) |
| POST | `/v1/bluetooth/scan` | `{durationMs?}` (1–10 s) → `devices` mit `id`, `name`, `rssi`, `services`, `approved`; nur eine Suche gleichzeitig |
| PUT | `/v1/bluetooth/devices/{id}` | zulassen, `{name?}` |
| DELETE | `/v1/bluetooth/devices/{id}` | vergessen: trennen und entfernen |
| POST | `…/devices/{id}/connect` | Bedarf anmelden (verbinden bzw. verlängern) → `{connected, generation}` |
| POST | `…/devices/{id}/release` | Bedarf vorzeitig freigeben |
| GET | `…/devices/{id}/gatt` | Dienste und Merkmale mit Eigenschaften (Gesperrtes ausgeblendet) |
| POST | `…/devices/{id}/read` | `{service, characteristic}` → `{data}` (Base64) |
| POST | `…/devices/{id}/write` | `{service, characteristic, withResponse, lease, data \| packets[], generation?}` → `{written}`; je Paket ein Schreibvorgang, in Reihenfolge |
| POST | `…/devices/{id}/subscribe`, `…/unsubscribe` | Abo eines Merkmals |
| GET | `…/devices/{id}/notifications` | letzte Meldungen je Merkmal (höchstens 32) der laufenden Verbindung, mit `generation` |
| POST | `…/devices/{id}/lease` | Belegung holen, `{waitMs?}` (höchstens 30 s) → `{lease, ttlMs}` |
| POST | `…/devices/{id}/lease/renew` | `{lease}` verlängern (sonst Ablauf nach 5 s) |
| POST | `…/devices/{id}/lease/release` | `{lease}` freigeben → `{released}`; wiederholbar |

`state` in `GET /v1/bluetooth` ist der Funkzustand des Macs (`poweredOn`,
`poweredOff`, `unauthorized`, `unsupported`, `resetting`) oder ein Zustand des
Hilfsprogramms: `unknown` heißt, das Hilfsprogramm läuft noch nicht, weil seit
dem Start des Agenten noch niemand Bluetooth gebraucht hat (kein Fehler);
`starting` beim ersten Start, `helper_restarting` nach einem Absturz bis zur
nächsten Meldung. macOS wertet die Bluetooth-Freigabe nur beim Start eines
Prozesses aus: meldet das laufende Hilfsprogramm `unauthorized`, startet Connect
es beim nächsten Bluetooth-Aufruf (Suche, Verbinden, Belegen, Abo, Schreiben)
neu und wartet darauf; `GET /v1/bluetooth` stößt den Neustart nur an und
antwortet sofort mit dem bekannten Zustand, erst die nächste Abfrage zeigt den
neuen. Höchstens alle 10 Sekunden, damit eine in den Systemeinstellungen
erteilte Freigabe ohne Neustart von Connect greift. `GET /v1/status` startet
nichts neu.
`unauthorized` heißt, die Freigabe unter **Systemeinstellungen → Datenschutz &
Sicherheit → Bluetooth** fehlt.

Connect verbindet ein zugelassenes Gerät bei Bedarf (Verbindungsaufbau
höchstens 10 s), hält die Verbindung nach dem letzten Zugriff 60 s und gibt das
Gerät dann frei, damit andere Geräte (z. B. die Kassen-App) es verbinden
können. Bricht die Verbindung während eines Bedarfs ab, verbindet Connect still
neu und stellt die Abos wieder her; jede Verbindung trägt eine neue
`generation`. Schreiben geht nur mit gültiger Belegung; endet eine Belegung
ohne Freigabe, setzt Connect die Verbindung zurück, damit kein halber Auftrag
im Gerät hängt.

Ereignisse über `/v1/events`: `bluetooth.state` (`{state}`), `bluetooth.device`
(`{id, connected, generation, reason?}`) und `bluetooth.notification`
(`{id, service, characteristic, data, generation, seq}`). Geschriebene Bytes
kommen nie ins Log, nur Gerät, Merkmal, Länge, Dauer und Ergebnis.

Fehlercodes: `bluetooth_unsupported`, `bluetooth_unauthorized`,
`bluetooth_off`, `bluetooth_unavailable`, `bluetooth_device_unknown` (nicht
zugelassen), `bluetooth_device_not_found`, `bluetooth_unreachable` (vielleicht
mit einem anderen Gerät verbunden), `bluetooth_blocked`,
`bluetooth_characteristic_unknown`, `bluetooth_operation_unsupported`,
`bluetooth_lease_required`, `bluetooth_busy`, `bluetooth_write_too_long`,
`bluetooth_write_failed`, `bluetooth_disconnected`,
`bluetooth_too_many_devices`. Das Nachrichtenprotokoll zwischen Agent und
Hilfsprogramm steht in `docs/bluetooth-protokoll.md`.

## Betrieb ab 1.5.0: Kennung, Status, Wiederfinden, Sperren

Grundsatz: **nie schlechter als 1.4.2.** Was eine Neuerung nicht sicher
entscheiden kann, verhält sich wie 1.4.2, und jede Neuerung lässt sich einzeln
abschalten (siehe unten).

**Fähigkeiten.** Die Kasse entscheidet an `features` in `GET /v1/status`, nie an
der Versionsnummer:

| Fähigkeit | Inhalt |
|---|---|
| `identity` | Kennung je Drucker (`identity: {model, serial, mac, state}`), `installationId` (auch ohne Token) |
| `printer_status` | `paper` (`ok`, `near_end`, `out`, `unknown`), `cover` (`closed`, `open`, `unknown`), `readiness` (`ready`, `not_ready`, `unknown`), `statusAt` je Drucker, `POST /v1/printers/{id}/status`, `paper_out`, `cover_open`, `printer_not_ready` |
| `relocate` | Wiederfinden, `endpoint` in Terminal-Antworten, `locate` für Drucker und Terminal |
| `busy_lock` | Update-, Neustart- und Schlafsperre, `betrieb.lock`, `terminal_busy` |
| `diagnosis` | `GET /v1/diagnosis` |
| `restart` | `POST /v1/restart` (nur macOS und Linux mit eingerichtetem Autostart) |

Neue Felder stehen nur da, wenn sie etwas sagen: ein Drucker, über den nichts
bekannt ist, sieht in `GET /v1/printers` aus wie in 1.4.2.

**Kennung.** Beim Anlegen und beim ersten gelungenen Kontakt ermittelt Connect
Modell, Seriennummer und MAC: aus den mDNS-TXT-Einträgen der letzten Suche, aus
`GS I 67/68` über eine eigene, kurze Verbindung auf 9100 (nur an Geräte, die
vorher gültig auf `DLE EOT` antworten) und aus der ARP-Tabelle (nur im selben
Netz). Vor jedem Bon vergleicht Connect die MAC (ohne Bytes an den Drucker);
weicht sie ab oder fehlt sie, fragt es `GS I 68`. **Nur eine andere
Seriennummer beweist einen anderen Drucker.** Dann sucht Connect schnell; ist
der eigene Drucker woanders, druckt es dort. Sonst druckt es an die
eingerichtete Adresse wie bisher, merkt `identity.state: conflict` und
übernimmt die fremde Kennung nie. Was sich nicht entscheiden lässt, ist
unbekannt: gedruckt wird wie bisher. Die Druckverbindung trägt immer genau die
Bytes der Kasse; alle Fragen gehen über eigene Verbindungen davor. Prüfungen
kosten einen Bon höchstens 500 ms; ein Gerät, das nicht antwortet, wird 10 min
nicht mehr gefragt. `printer_mismatch` gibt 1.5.0 nicht aus – ein Konflikt
blockiert den Druck nie.

**Papier und Deckel.** Vor jedem Bon `DLE EOT 2` und `DLE EOT 4` (9100) bzw.
die Statusbits eines leeren ePOS-Auftrags. Gezählt wird nur eine Antwort mit
den festen Bits; blockiert wird nur bei Papierende oder offenem Deckel
(`paper_out`, `cover_open`, kein Byte gesendet), „fast leer“ druckt. Ein
Epson TM-T20III meldet beides nicht als Bits, sondern schweigt (Gerätetest):
Hat ein Drucker schon einmal gültig auf `DLE EOT` geantwortet
(`statusCapableAt` in der `config.json`), heißt Schweigen auf zwei Verbindungen
nacheinander „nicht bereit“ – `printer_not_ready`, kein Byte gesendet,
höchstens 1,5 s. Ein Drucker, der nie geantwortet hat, druckt wie bisher. Solange
eine Kasse offen ist (gültiger Token in den letzten 2 min), fragt Connect jeden
Drucker alle 60 s ab – ein Takt für alle Kassen, über die Warteschlange, nie
neben einem Bon.

**Wiederfinden.** Scheitert die Verbindung zu einem Drucker vor dem ersten
Byte, sucht Connect höchstens 4 s (ARP-Tabelle nach der MAC, mDNS nach
Seriennummer) und druckt denselben Auftrag an der neuen Adresse; sonst später
gründlich (Netzscan, höchstens einmal in 2 min, nie während einer Zahlung).
Übernommen wird nur genau ein bestätigter Kandidat: `config.json`, Logzeile,
`relocations` (die letzten 20) und das Ereignis `printer.relocated` bzw.
`terminal.relocated`. Die Kasse zeigt einen Adresswechsel nie.

**Sperren.** Druckaufträge und lange Terminal-Aufrufe zählen als laufende
Vorgänge, für alle Kassen und Tabs zusammen. Solange einer läuft, lehnt
`POST /v1/update` mit `update_device_busy` ab und `POST /v1/restart` mit
`restart_busy`; beginnt einer während des Ladens, öffnet der Installer erst
danach (Phase `waiting`, höchstens 10 min). Im Datenordner steht dann
`betrieb.lock`; das postinstall wartet höchstens 5 min darauf. Am Mac hält ein
einziges `caffeinate -i -w <pid> -t 360` den Rechner wach, unter Windows setzt
Connect den Leerlauf-Zähler alle 30 s zurück. Jede Sperre läuft ab: ein
Vorgang nach 6 min, `betrieb.lock` nach 6 min, `caffeinate` nach 6 min oder mit
Connect.

**Not-Aus je Neuerung.** In der `config.json` schaltet `disabledFeatures` jede
Neuerung einzeln ab; abgeschaltet verhält sich Connect dort wie 1.4.2, und die
zugehörige Fähigkeit verschwindet aus `features`. `doctor` und die Diagnose
zeigen, was abgeschaltet ist.

```json
{ "disabledFeatures": ["printer_status", "status_poll"] }
```

| Name | schaltet ab |
|---|---|
| `printer_identity` | Kennung ermitteln und vor dem Druck prüfen |
| `printer_status` | Papier und Deckel vor dem Druck und auf Zuruf |
| `printer_relocate` | Wiederfinden der Drucker |
| `terminal_relocate` | Umleiten und Wiederfinden des Terminals, `endpoint` |
| `status_poll` | den 60-s-Takt bei offener Kasse |
| `sleep_lock` | die Schlafsperre |
| `busy_lock` | Update- und Neustart-Sperre, `betrieb.lock`, `terminal_busy` |

**Installationskennung.** Beim ersten Start entsteht `installationId` (UUID v4)
und ändert sich nie; `GET /v1/status` nennt sie auch ohne Token. Zwei
angemeldete Benutzer am Rechner haben zwei Connect mit zwei Kennungen.

## Aktualisieren

Ab 1.4.0 aktualisiert sich Connect am Mac auf einen Klick aus der Kasse: Die
Kasse ruft `POST /v1/update`, Connect lädt das Paket der neuesten Version von
GitHub (nur `kreiseck-at/kasseneck-connect`, Adresse und Version kommen allein
aus `latest.json`), prüft Größe und SHA-256 und mit `pkgutil` und `spctl`, dass
es mit einer „Developer ID Installer“-Identität des Teams `6KMT4H4CNE` signiert
und von Apple notarisiert ist, und öffnet erst dann den Installer. Bestätigen
und das Kennwort bzw. Touch ID gibt der Mensch ein; still installiert wird nie.
Kopplung, Drucker, Zertifikate und Bluetooth-Freigabe bleiben erhalten.
Windows und Linux: `GET /v1/update` nennt die neueste Version, aktualisiert
wird über den Download. Geladene Pakete liegen unter `updates/` im
Konfigurationsordner und werden nach 24 Stunden entfernt.

## Fehlersuche

```bash
kasseneck-connect doctor
```

Die Diagnose nennt Version, Programmpfad, Konfigurations- und Logpfad, ob
gekoppelt ist, auf welchem der Ports 27182–27189 ein Agent antwortet, am Mac
den HTTPS-Zugang (Port, Ablauf des Zertifikats, ob ihm vertraut wird), die
eingetragenen Drucker mit ihrem aktuellen Zustand, den Autostart-Zustand und die
letzten Fehlerzeilen aus dem Log.

| Symptom | Nächster Schritt |
|---|---|
| „Kein Agent erreichbar" | Läuft er? `kasseneck-connect run` im Terminal starten und die Ausgabe lesen |
| Kasse findet den Agenten nicht | `doctor` zeigt den tatsächlichen Port; Firewall auf der Loopback-Adresse prüfen |
| Kasse meldet „nicht gekoppelt" | `kasseneck-connect pair` und den Code neu eingeben |
| Safari findet Connect nicht (Chrome schon) | `doctor` → HTTPS-Zeile; bei „vertraut nein“ `kasseneck-connect zertifikat-vertrauen` |
| Bluetooth: `bluetooth_unauthorized` | **Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth** → „Kasseneck Connect“ einschalten |
| Bluetooth: `bluetooth_unreachable` | Gerät an? Hält es gerade ein anderes Gerät (Kassen-App, Handy)? Dort schließen und erneut versuchen |
| `doctor`: „Bluetooth-Hilfsprogramm: fehlt“ | Connect neu installieren (das Hilfsprogramm liegt im App-Paket) |
| Drucker `offline` | IP und Port prüfen (`doctor`), Gerät anpingen, `POST /v1/printers/discover` |
| Mac: Drucker oder Terminal „nicht erreichbar“, Meldung nennt „Lokales Netzwerk“ | **Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk** → „Kasseneck Connect“ einschalten. `doctor` im Terminal braucht die Freigabe nicht – zeigt es den Drucker `online`, die Kasse aber nicht, fehlt sie |
| Terminal: `terminal_unreachable` | Es ging nichts ans Terminal. Terminal an? Im selben Netz wie der Rechner? IP am Terminal ablesen oder `POST /v1/terminal/discover` |
| Bon kam nicht | Log ansehen: `logs/connect.log`; bei `timeout` mit `mayHavePrinted` erst am Gerät nachsehen |
| Agent startet nach dem Neustart nicht | `doctor` → Autostart-Zeile; notfalls `install-autostart` erneut |

Ins Log kommen **keine Beleginhalte** — nur IDs, Fehlercodes und Klartext.
Die Datei darf deshalb bedenkenlos an den Support gehen. `connect.log` wandert
täglich und ab 5 MB in ein Archiv; alle Logdateien zusammen bleiben unter
50 MB. `launchd.out.log` und `launchd.err.log` kürzt der Start auf 256 KB, wenn
sie größer als 1 MB sind.

`GET /v1/diagnosis` (ab 1.5.0, mit Token) liefert dem Support Version,
Systemangaben, `installationId`, Ports, `features`, die Konfiguration nach
Positivliste, Zustand je Drucker und Terminal, die letzten Fehler und
Logzeilen, den Update-Stand und die letzten Adresswechsel – nie Token-Hashes,
Kopplung, Zertifikate oder Schlüssel; sechsstellige Zahlen sind geschwärzt.

## Entwicklung

```bash
dart pub get
dart test
dart analyze
dart format .
```

Die Tests mit echtem `openssl` nehmen `/usr/bin/openssl` (am Mac LibreSSL, wie
beim Kunden). `KASSENECK_TEST_OPENSSL` gibt ihnen ein anderes Programm vor, etwa
OpenSSL aus Homebrew: `KASSENECK_TEST_OPENSSL=/opt/homebrew/bin/openssl dart test`.
Die Linux-CI hat OpenSSL 3.0; wie das Namen schreibt (`CN = …`), zeigt am Mac
`openssl@1.1`.

Bauen:

```bash
tool/build_macos.sh              # -> "build/Kasseneck Connect.app" und build/kasseneck-connect-macos-<arch>
tool/pkg/macos/build_pkg.sh      # -> build/KasseneckConnect-<version>-macos-<arch>.pkg
tool/build_linux.sh              # -> build/kasseneck-connect-linux-<arch>
tool/build_linux_deb.sh          # -> build/KasseneckConnect-<version>-linux-<arch>.deb
powershell -File tool\build_windows.ps1   # Binary + (mit Inno Setup) Installer
```

`tool/build_macos.sh` baut die Dart-Binary, das Bluetooth-Hilfsprogramm
(`swift build` in `native/macos/KasseneckBluetooth`, Tests mit
`swift test --package-path native/macos/KasseneckBluetooth`) und setzt beide
mit `tool/macos/Info.plist.in` und `tool/macos/AppIcon.icns` zum App-Paket
zusammen. Der Ordnername `Kasseneck Connect.app` ist Absicht: macOS zeigt ihn im
Bluetooth-Dialog und in den Systemeinstellungen. Weil er ein Leerzeichen hat,
steht jeder Pfad dorthin in Anführungszeichen (`test/macos_bundle_test.dart`
prüft das für die Skripte und die CI). Das Symbol ist eingecheckt;
`python3 tool/macos/app_symbol.py` zeichnet es aus der Markengeometrie neu
(braucht Pillow und `iconutil`, nur wer es ändert).

`tool/_common.sh` hält die Namensregel und die Architekturnormalisierung
(`x86_64`/`amd64` → `x64`, `aarch64` → `arm64`) an einer Stelle; alle
Build-Skripte laden sie. `build_linux_deb.sh` braucht `dpkg-deb` und
überspringt sich mit einem Hinweis, wo es das nicht gibt (z. B. auf einem Mac)
— das echte `.deb` entsteht in der CI auf ubuntu.

Veröffentlichen als GitHub Release (von Hand, braucht eine angemeldete `gh`,
`gh auth login` mit Schreibrecht auf dieses Repo). **Reihenfolge einhalten**
— `build/` zuerst leeren, dann bauen, dann veröffentlichen:

```bash
rm -rf build                     # alte Artefakte weg, sonst wandern sie mit
tool/build_macos.sh && tool/pkg/macos/build_pkg.sh
#   … dazu die Artefakte der übrigen Systeme nach build/ legen
tool/release.sh --dry-run        # zeigt latest.json und die geplanten gh-Kommandos
tool/release.sh                  # legt das Release v<version> mit allen Assets an
```

Veröffentlicht werden nur die vier Installer (unversioniert kopiert, s. o.)
und `latest.json`. Die nackten Binaries (`build/kasseneck-connect-*`) tragen
**keine Version im Namen** und sind kein Release-Asset — ein nicht geleertes
`build/` würde aber unbemerkt eine Installer-Datei der Vorversion mit hochladen.
Deshalb bricht `release.sh` ab, sobald in `build/` eine Auslieferungsdatei
einer fremden Version liegt — ebenso, wenn das Release-Tag `v<version>` auf
GitHub schon existiert. Fehlende Plattform-Dateien in `build/` werden
übersprungen, nicht abgebrochen (ein Release entsteht auf mehreren Rechnern)
— `release.sh` warnt je fehlender Datei und listet am Ende noch einmal alle
ausgelassenen Plattformen.

Die CI (`.github/workflows/ci.yml`) fährt bei jedem Push und jedem Pull Request
`dart format --set-exit-if-changed`, `dart analyze --fatal-infos` und
`dart test`, danach die Build-Matrix (macOS arm64/x64, Windows, Linux) und legt
die Ergebnisse als Artefakte ab. Im macOS-Lauf kommen `swift test` für das
Hilfsprogramm, eine Startprobe der Binary im App-Paket und `plutil -lint` der
Info.plist dazu. Ein GitHub Release legt die CI **nicht** an
— das bleibt `tool/release.sh` von Hand vorbehalten.

### Signierung & Notarisierung

Ausgeliefert wird für macOS ab 1.0.2 nur noch signiert und notarisiert. Nötig
sind zwei Zertifikate im Schlüsselbund des Entwicklungsrechners (Apple
Developer Program, Team-ID `6KMT4H4CNE`):

| Zweck | Identität |
|---|---|
| Binary (`codesign`) | `Developer ID Application: POST NOW e.U. (6KMT4H4CNE)` |
| Paket (`productsign`) | `Developer ID Installer: POST NOW e.U. (6KMT4H4CNE)` |

Nachsehen, was vorhanden ist: `security find-identity -v`. Die Build-Skripte
suchen sich die passende Identität selbst; `KASSENECK_SIGN_APP` bzw.
`KASSENECK_SIGN_PKG` stechen die Suche, falls einmal mehrere Zertifikate im
Schlüsselbund liegen.

Signiert wird mit **Hardened Runtime** (Pflicht für die Notarisierung) und mit
`tool/entitlements-macos.plist`. Die Berechtigungsdatei ist keine Zierde: eine
mit `dart compile exe` gebaute Binary startet unter Hardened Runtime **nicht**
— der Kernel schießt sie beim Start wortlos ab (SIGKILL, Rückgabewert 137),
weil die Dart-Laufzeit den angehängten AOT-Schnappschuss ausführbar abbildet.
Erst `com.apple.security.cs.allow-unsigned-executable-memory` macht sie wieder
startfähig; `allow-jit` allein genügt nicht. Beide Build-Skripte machen nach
dem Signieren deshalb eine Startprobe.

Das App-Paket wird in fester Reihenfolge signiert (`sign_app_bundle` in
`tool/_common.sh`): zuerst das Hilfsprogramm
`Contents/MacOS/kasseneck-bluetooth` (Hardened Runtime, ohne Berechtigungen),
dann das Paket mit `tool/entitlements-macos.plist` — das signiert die
Dart-Binary als Hauptprogramm und versiegelt Info.plist, Symbol und
Hilfsprogramm. `build_pkg.sh` übernimmt ein schon mit Developer ID signiertes
App-Paket unverändert.

Für die Notarisierung braucht `notarytool` einmalig ein Schlüsselbund-Profil
(Vorgabename `kasseneck-connect`, anders über `KASSENECK_NOTARY_PROFILE`).
Das Kennwort ist ein **app-spezifisches Kennwort** der Apple-ID
(appleid.apple.com → Anmeldung & Sicherheit), nicht das Apple-ID-Kennwort:

```bash
xcrun notarytool store-credentials kasseneck-connect \
  --apple-id "<apple-id>" --team-id 6KMT4H4CNE --password "<app-kennwort>"
```

Der Ablauf für ein Release:

```bash
rm -rf build
tool/build_macos.sh              # signiert Binary und App-Paket (Hardened Runtime + Zeitstempel)
tool/pkg/macos/build_pkg.sh      # übernimmt das signierte App-Paket, signiert das .pkg
tool/notarize_macos.sh build/KasseneckConnect-<version>-macos-<arch>.pkg
tool/release.sh                  # holt eine fehlende Notarisierung selbst nach
```

`tool/release.sh` prüft jedes macOS-Paket vor dem Hochladen genau so wie
Connect vor dem Ein-Klick-Update (`lib/src/update/mac_package.dart`): mit
„Developer ID Installer“ des Teams `6KMT4H4CNE` signiert, Kette bis „Apple
Root CA“, von Gatekeeper als „Notarized Developer ID“ angenommen. Fehlt nur das
Ticket, reicht es das Paket über `tool/notarize_macos.sh` ein – vor den
unversionierten Kopien, weil `stapler` die Datei verändert und die Prüfsumme in
`latest.json` das fertige Paket meinen muss. Alles andere bricht ab, auch im
Probelauf und ohne Schalter dagegen: unsigniert, fremdes Team, kein
`notarytool`-Profil, Notarisierung gescheitert, kein Ticket, Gatekeeper lehnt
ab, kein `xcrun`. Veröffentlicht wird dann nichts.

`tool/pkg/macos/build_pkg.sh` bricht ohne Developer-ID-Installer-Identität
gleich zu Beginn ab und ebenso, wenn das App-Paket in der Nutzlast keine
gültige Developer-ID-Application-Signatur trägt oder die fertige Paketsignatur
die Prüfung oben (ohne Notarisierung) nicht besteht. Unter dem
Auslieferungsnamen steht so nie ein ungeprüftes Paket.

Läuft eines der Signierzertifikate (Blatt oder Zwischenstelle) in weniger als
60 Tagen ab, warnen `build_macos.sh`, `build_pkg.sh` und `release.sh` laut
(Frist über `KASSENECK_CERT_WARN_DAYS`). Das heutige Paar läuft am 01.02.2027
ab, die Warnung kommt also ab dem 04.12.2026. Ein Ablauf bricht nichts ab:
ein schon signiertes Paket bleibt dank Zeitstempel gültig, nur neu signieren
geht nicht mehr.

Prüfen lässt sich das Ergebnis von Hand:

```bash
codesign -dv --verbose=4 "build/Kasseneck Connect.app"        # Authority-Zeilen
codesign --verify --strict --deep "build/Kasseneck Connect.app"
pkgutil --payload-files build/KasseneckConnect-*.pkg | grep 'Kasseneck Connect.app/Contents/MacOS'  # beide Programme
pkgutil --check-signature build/KasseneckConnect-*.pkg
xcrun stapler validate build/KasseneckConnect-*.pkg
spctl -a -vv -t install build/KasseneckConnect-*.pkg           # Urteil von Gatekeeper
```

Auf den CI-Runnern liegt kein Zertifikat. Dort läuft
`tool/pkg/macos/build_pkg.sh --testbau`: das Paket darf unsigniert bleiben,
heißt aber `KasseneckConnect-<version>-macos-<arch>-testbau.pkg` – diesen
Namen sucht `tool/release.sh` nie. `tool/build_macos.sh` warnt ohne Zertifikat
nur. Die CI-Artefakte sind Bauprobe, kein Auslieferungsstand. Ausgeliefert
wird ausschließlich, was auf dem Entwicklungsrechner signiert und notarisiert
entstanden ist.

Windows- und Linux-Artefakte bleiben vorerst unsigniert (siehe die Hinweise
bei der Installation).

### Entwicklerwerkzeuge

`tool/scan_debug.dart` zeigt, welche Netze die Druckersuche abklopft.
`tool/bluetooth_probe.dart` spricht die lokale Bluetooth-API wie die Kasse und
zeigt Bytes nur als Hex (Gerätetest am Drucker, nicht gegen echte Geräte in
Tests):

```bash
dart run tool/bluetooth_probe.dart koppeln <code> --token-datei ~/.connect-token
dart run tool/bluetooth_probe.dart --token-datei ~/.connect-token scan
dart run tool/bluetooth_probe.dart --token-datei ~/.connect-token approve <id>
dart run tool/bluetooth_probe.dart --token-datei ~/.connect-token print <id> beleg.bytes.hex [--paket 180] [--ohne-antwort] [--warten 5]
dart run tool/bluetooth_probe.dart --token-datei ~/.connect-token watch <id>
```

Standard ist HTTPS über den Port aus `GET /v1/status`; `--http` bleibt bei
reinem HTTP, `--port` legt den HTTP-Port fest. `print` belegt das Gerät, hält
die Belegung, abonniert `ff00`/`ff03`, sendet die Pakete und gibt alle Meldungen
mit Zeit seit dem Start aus. `--abbrechen-nach <n>` (und Strg-C) beenden den
Prozess ohne Freigabe – so lässt sich das Zurücksetzen der Belegung nach 5 s
prüfen. Der Token steht nie auf der Ausgabe. Das Werkzeug schickt die Herkunft
der Kasse mit: für lokale Programme ist allein der Token die Schranke, die
Herkunftsliste schützt nur vor fremden Webseiten im Browser.

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

Ohne `Origin`-Kopfzeile (curl, Diagnosewerkzeuge) sind nur `GET /v1/status`,
`POST /v1/pair` und `POST /v1/pair/request` erreichbar; alles andere verlangt
eine erlaubte Herkunft **und** einen Token. `POST /v1/pair/request` gibt dabei
nichts preis: es lässt lediglich auf demselben Rechner ein Browserfenster
aufgehen, in dem der Code steht.

---

© 2026 Kreiseck – Software Solutions. Alle Rechte vorbehalten.
