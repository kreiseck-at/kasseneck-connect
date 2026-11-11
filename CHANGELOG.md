# Änderungen

Alle nennenswerten Änderungen an Kasseneck Connect. Die Versionsnummer folgt
[SemVer](https://semver.org/lang/de/); sie steht in `pubspec.yaml` und
`lib/src/version.dart` und wird über `GET /v1/status` sowie im Update-Feed
gemeldet.

## Unveröffentlicht

Grundsatz: nie schlechter als 1.4.2 – „es darf nicht kaputt gehen“ geht vor
Abdeckung. Jede Neuerung lässt sich in der `config.json` einzeln abschalten
(`disabledFeatures`), abgeschaltet verhält sich Connect dort wie 1.4.2. Neue
Felder, Routen und Codes sind additiv; die Kasse entscheidet an `features`.

- **Nur bewiesene Modelle:** Papier und Deckel, `printer_not_ready`, die
  Kennungsprüfung vor dem Bon und der Statustakt laufen nur für Drucker, deren
  über `GS I 67` gelesenes Modell im Gerätetest bewiesen ist
  (`bewieseneModelle`). Jeder andere Drucker druckt exakt wie bis 1.4.2.
- **Gerätetest Epson TM-T20III** (10. und 11.11.2026, Firmware 20.05,
  Netzwerk) – damit das erste bewiesene Modell: `DLE EOT 2/4` antworten
  sofort; Deckel offen oder Rolle heraus: Verbindung angenommen, keine Antwort
  am Stück; nach dem Schließen antwortet er nach rund 3 s wieder; nach einem
  Bon von 8 KB schweigt er rund 0,5 s und antwortet nach 1,0 s, auch während
  er noch druckt.
- **Installationskennung:** `installationId` (UUID v4) in `GET /v1/status`,
  auch ohne Token; zusätzlich in `installation-id`, damit ein Zurückstufen sie
  nicht verliert. Der Start scheitert nie an ihr.
- **Gerätekennung der Drucker** aus mDNS-TXT (Frist 0,5 s), `GS I 67/68` und
  ARP – beim Anlegen, nach einer Druckersuche und auf Zuruf, nie wegen eines
  Bons. Nach einem `GS I` ohne gültige Antwort folgt keines mehr; ein Gerät,
  das `DLE EOT`, aber nicht `GS I 67` beantwortet, bekommt `GS I` nur noch beim
  Anlegen (`idQueryUnansweredAt`, `PUT` setzt es zurück). Nur eine andere
  Seriennummer beweist einen anderen Drucker; der Druck
  wird dadurch nie blockiert. Steht dort dauerhaft ein anderer und ist der alte
  nirgends zu finden, übernimmt Connect die neue Kennung (`relocations` mit
  `kind: replaced`). `POST /v1/printers/discover` nennt je Fund `model` und
  `serial`.
- **Papier und Deckel** vor jedem Bon (`DLE EOT 2/4`): `paper_out` und
  `cover_open` statt eines stillen „gedruckt“, kein Byte gesendet; „fast
  leer“ druckt. Ein Drucker, der schon einmal gültig auf `DLE EOT`
  geantwortet hat (`statusCapableAt`) und jetzt 30 s lückenlos beobachtet
  schweigt, ist nicht bereit (Epson TM-T20III mit offenem Deckel oder ohne
  Papier): `printer_not_ready`, kein Byte gesendet; kürzeres Schweigen (etwa
  während eines fremden Bons) druckt wie bisher. Lückenlos heißt: solange er
  schweigt, fragt Connect alle 5 s nach (über die Warteschlange, nie neben
  einem eigenen Bon); liegen zwei stumme Beobachtungen mehr als 10 s
  auseinander, beginnt die Strecke neu. Vor einem Bon fragt Connect nicht,
  solange der eigene vorige noch druckt (Bons direkt hintereinander ohne
  Zuschlag). Statustakt alle 60 s bei offener Kasse,
  `POST /v1/printers/{id}/status`, Felder `paper`, `cover`, `readiness`,
  `statusAt`.
- **Langsame Freigabe:** lehnt ein Drucker die Druckverbindung direkt nach der
  eigenen ab, versucht Connect dieselbe Adresse bis zu 3 s lang erneut und
  prüft danach nicht mehr vor seinen Bons. Das gilt auch auf dem Weg wie bis
  1.4.2 nach einer eigenen Abfrage-Verbindung (Erkennung nach dem Anlegen oder
  einer Suche, Statusabfrage, Suche): der Testdruck direkt nach dem Anlegen
  geht so wie in 1.4.2.
- **Wiederfinden:** Drucker unter neuer Adresse nur mit derselben über
  `GS I 68` gelesenen Seriennummer (die MAC ist nur ein Hinweis), nie unter der
  Adresse eines anderen eingerichteten Druckers; die gründliche Suche schickt
  Bytes nur an Geräte mit derselben Herstellerkennung (OUI) wie die gemerkte
  MAC und sucht ohne gemerkte MAC gar nicht – andere Geräte im Netz bekommen
  wie bis 1.4.2 kein Byte. Terminal per TID; Terminal-Aufrufe ohne Verbindung laufen genau einmal an der
  bestätigten Adresse derselben TID (Geld bei älterer Bestätigung erst nach
  einer Diagnose dort). `endpoint` in Terminal-Antworten, `locate` für Drucker
  und Terminal, `device_not_found`. Ein ausgeschalteter Drucker kostet nie
  länger als bis 1.4.2. Die Terminal-Suche im Hintergrund läuft nur bei
  offener Kasse, im Abstand 5, 15, dann 60 min.
- **TID ohne führende Nullen:** Connect schickt die TID so, wie das Terminal
  sie annimmt (`012345678` → `12345678`; HPS 1.14.4 lehnt die Form mit Null
  ab). Meldet ein Terminal darauf „Invalid TID“, geht derselbe Aufruf genau
  einmal in der Form der Kasse hinaus (wie 1.4.2). Die gemerkte Adresse des
  Terminals überschreibt kein älterer Speichervorgang, und die Suche
  übernimmt nichts, wenn inzwischen ein anderes Terminal gemerkt ist. Die Seriennummer des Terminals (`sn`) wird zusätzlich gemerkt.
- **terminal_busy:** ein zweiter langer Terminal-Aufruf, Diagnose, Test oder
  Suche während einer Zahlung bekommt sofort `terminal_busy` (mit
  `terminalHttpStatus: 409`); eine Suche, die eine Zahlung unterbricht, meldet
  `incomplete: true`.
- **Sperren bei laufenden Vorgängen:** `update_device_busy`, Warten vor dem
  Installer (Phase `waiting`), `betrieb.lock` samt Warten im postinstall,
  `POST /v1/restart` mit `restart_busy`, Schlafsperre nur während Druck und
  Zahlung. Jede Sperre läuft nach spätestens 6 min ab; überlappende Vorgänge
  frischen sie auf. Ein Fehler beim Schreiben von `betrieb.lock` bleibt beim
  einen Schritt (Logzeile), der nächste Vorgang schreibt wieder.
- **Diagnose:** `GET /v1/diagnosis` nach Positivliste, Kopplungscodes
  geschwärzt; `doctor` nennt abgeschaltete Neuerungen.
- **Log:** 5 MB je Datei, 50 MB insgesamt; `launchd.*.log` beim Start gekürzt.
  Zwei Prozesse, die zugleich rotieren, überschreiben einander keinen Teil.
- **Terminal-Aufrufe** haben eine Frist für Verbindung, Kopf und Rumpf
  zusammen.
- **Konfiguration:** Felder einer neueren Fassung überleben das Speichern.

## 1.4.2 — 2026-11-09

- **Terminal: „nichts gesendet“ ist jetzt erkennbar.** Kommt keine Verbindung
  zum Terminal zustande (abgelehnt, keine Route, kein Aufbau in 10 s), meldet
  Connect den neuen Code `terminal_unreachable`: die Anfrage hat das Terminal
  nachweislich nicht erreicht. `terminal_offline` heißt nur noch „Verbindung
  stand und ist abgerissen“ (Ausgang offen), `timeout` und `terminal_error`
  bleiben, wie sie waren. Der Verbindungsaufbau hat bei jedem Aufruf ein
  eigenes Limit von 10 s – eine falsche Terminal-IP blockierte eine Zahlung
  bisher bis zu 4 Minuten. Der Weckversuch der Probe greift auch bei
  `terminal_unreachable`; Zahlung und Gutschrift wiederholt Connect weiterhin
  nie. Ein Proxy aus der Umgebung gilt für das Terminal nicht mehr.
- **Konfiguration geht nicht mehr verloren.** Jedes Speichern behält die
  vorige gute Fassung als `config.json.bak`. Eine unbrauchbare `config.json`
  (kein JSON, leer, nicht lesbar) legt Connect einmalig als
  `config.json.defekt-<UTC-Zeitstempel>` ab (Rechte 600), meldet sie als
  Fehler und nimmt die Sicherung. Bisher fiel er still auf die
  Standardkonfiguration zurück, und das nächste Speichern überschrieb
  Kopplungen und Drucker endgültig.
- **macOS „Lokales Netzwerk“:** `Kasseneck Connect.app` trägt jetzt
  `NSLocalNetworkUsageDescription` (Text im Freigabe-Dialog) und die
  Druckerdienste in `NSBonjourServices`. Scheitert eine Verbindung zu Drucker
  oder Terminal am Mac mit „No route to host“, nennt die Meldung den Weg zur
  Freigabe; die Codes bleiben (`printer_offline`, `terminal_unreachable`).
  `detail.reason` nennt bei Druckfehlern zusätzlich den Betriebssystem-Fehler.
- **Release nur signiert und notarisiert:** `tool/release.sh` bricht bei einem
  macOS-Paket ohne Developer-ID-Signatur des Teams, ohne Notarisierung oder
  ohne Zusage von Gatekeeper ab (bisher: Warnung und trotzdem veröffentlicht);
  es prüft wie der Agent vor dem Ein-Klick-Update. `build_pkg.sh` bricht ohne
  beide Signaturen ab; die CI baut mit `--testbau` (Name `…-testbau.pkg`, nie
  veröffentlicht). Alle drei Skripte warnen, wenn ein Signierzertifikat in
  weniger als 60 Tagen abläuft.

## 1.4.1 — 2026-11-02

- Keine Änderung am Verhalten. Versionsschritt, an dem die Aktualisierung auf
  einen Klick aus der Kasse (ab 1.4.0) am Gerät erprobt wird.

## 1.4.0 — 2026-11-02

- **Aktualisieren auf einen Klick (macOS):** `GET /v1/update` nennt die
  neueste Version aus `latest.json` (höchstens alle 6 Stunden abgerufen, die
  Antwort wartet nie länger als ~1 s), `POST /v1/update` lädt das Paket,
  prüft Größe, SHA-256, Signatur des Teams `6KMT4H4CNE` und Notarisierung und
  öffnet den Installer; Fortschritt als `update.progress`, Fehler als
  `update.failed`, vor dem Öffnen `agent.restarting`. Neue Fähigkeit `update`
  in `features`. Windows und Linux: nur Anzeige, Aktualisieren per Download.
- **Systemangaben im Status:** mit Token zusätzlich `osVersion` und `arch`
  (für den Bestand in Kasseneck: welche Connect-Version auf welchem System).

## 1.3.0 — 2026-11-02

- **Bluetooth-Brücke (macOS):** die Kasse erreicht Bluetooth-Geräte, allen
  voran den Etikettendrucker, über die lokale API statt über Web Bluetooth —
  damit auch in Safari. Neue Pfade unter `/v1/bluetooth` (Zustand, Suche,
  Zulassen/Vergessen, Verbinden bei Bedarf, GATT, Lesen, Schreiben, Abos,
  Meldungspuffer, Belegung je Gerät) und die Ereignisse `bluetooth.state`,
  `bluetooth.device` und `bluetooth.notification`. Nutzbar sind nur
  zugelassene Geräte (höchstens 16, in der `config.json`); Sperrliste wie bei
  Web Bluetooth plus Firmware-Update-Dienste. Connect hält eine Verbindung 60 s
  nach, verbindet während eines Bedarfs still neu samt Abos und setzt die
  Verbindung zurück, wenn eine Belegung ohne Freigabe endet. Geschriebene
  Bytes kommen nie ins Log. `GET /v1/status` meldet die Fähigkeit in
  `features` (`bluetooth`), `doctor` zeigt das Hilfsprogramm und ob der Agent Bluetooth kann.
- **Bluetooth-Hilfsprogramm:** ein kleines Swift-Programm (CoreBluetooth)
  spricht Bluetooth, die Logik bleibt im Agenten. Der Agent startet es erst
  beim ersten Bluetooth-Aufruf, überwacht es und startet es nach Absturz oder
  Hänger neu; die übrigen Endpunkte laufen dabei unberührt weiter.
  CLI-Befehle berühren Bluetooth nie.
- **HTTPS-Zugang (macOS):** zusätzlich zu HTTP lauscht der Agent auf
  `https://127.0.0.1:27190` (Ausweich bis 27197), weil Safari eine Seite unter
  `https://` nicht an `http://127.0.0.1` lässt. Das Zertifikat stammt von einer
  lokalen Zertifizierungsstelle je Rechner (nur für `127.0.0.1` und
  `localhost`); der Installer vertraut ihr einmal (Kennwort oder Touch ID),
  sonst `kasseneck-connect zertifikat-vertrauen`. Das Serverzertifikat erneuert
  der Agent selbst.
- **App-Paket:** Connect liegt am Mac als `Kasseneck Connect.app` unter
  `/usr/local/kasseneck-connect/` (Agent und Hilfsprogramm, Info.plist mit
  Freigabetext, Symbol aus der Marke, kein Dock-Symbol). Der LaunchAgent
  startet die Binary im Paket, `/usr/local/bin/kasseneck-connect` zeigt
  hinein. macOS fragt die Bluetooth-Freigabe beim ersten Bluetooth-Zugriff
  im Namen von „Kasseneck Connect“. Ein Update von 1.2.x behält
  Konfiguration, Kopplungen und Drucker; beim ersten Update von 1.2.x fragt
  macOS einmal nach Kennwort oder Touch ID (Vertrauen in die lokale
  Zertifizierungsstelle), bei späteren Updates nicht mehr. Mindestens
  macOS 14.
- **Deinstallieren:** `uninstall.sh` entfernt zusätzlich das App-Paket, das
  Vertrauen in die lokale Zertifizierungsstelle und die Bluetooth-Freigabe.

## 1.2.5 — 2026-08-20

- **Terminal-Wachhalten:** Android-Terminals legen das WLAN im Ruhezustand
  schlafen; nach ein paar Minuten Stille antworten sie minutenlang gar nicht
  mehr. Der Agent merkt sich das Terminal beim ersten erfolgreichen Kontakt
  (Suche, Test oder Zahlung), schreibt die Adresse in die Konfiguration und
  berührt sie fortan alle 45 s per kurzem TCP-Verbindungsaufbau — keine Daten,
  keine Zahlung, nur genug, damit das Funkmodul nicht einschläft. Nach einem
  Neustart des Agenten läuft das Wachhalten von selbst weiter.

## 1.2.4 — 2026-08-20

- **Schlafende Terminals werden gefunden:** das Hobex-Terminal verschläft im
  WLAN-Stromsparmodus die erste Anfrage (sie weckt nur das Funkmodul) und
  antwortet auf die zweite in Millisekunden — belegt am Gerät. Die
  Terminal-Suche klopft jetzt 2 s je Adresse an (statt 300 ms; Budget 18 s),
  und Probe/Diagnose/Status machen bei Timeout oder „nicht erreichbar“ genau
  EINEN Weckversuch. Zahlungen bekommen den Automatismus bewusst nicht — die
  dürfen nie doppelt hinausgehen.

## 1.2.3 — 2026-08-20

- **Update startet den Agenten zuverlässig neu:** beim Aktualisieren über
  einen laufenden Agenten beendet `bootout` den alten Dienst asynchron — das
  sofortige `bootstrap` scheiterte, und der Agent blieb stehen (belegt beim
  Update auf 1.2.2; die Kasse meldete „nicht gefunden“). `install-autostart`
  wiederholt das Laden jetzt mit kurzen Pausen, bis launchd den Platz
  freigegeben hat.

## 1.2.2 — 2026-08-20

- **Terminal-Zahlung repariert:** HPS-Aufrufe gehen jetzt mit ausdrücklichem
  `Content-Length` hinaus. Ohne ihn schickte Dart den Rumpf chunked, und der
  eingebettete HPS-Server antwortete mit Klartext statt JSON — die Zahlung
  kam nie am Terminal an (belegt an hps 1.10.0). Der Fix ist end-to-end am
  Gerät verifiziert (Zahlung → Kartenflow → saubere JSON-Antwort).

## 1.2.1 — 2026-08-20

- **Terminal-Suche und -Test repariert:** das echte HPS kennt
  `GET /api/terminals` gar nicht („Endpoint not implemented“) — den Endpunkt
  gibt es nur in der Hobex-Cloud-API. Erkennungs-Probe ist jetzt die TID-lose
  Diagnose `GET /api/terminals/0/diagnosis`: das Terminal antwortet darauf mit
  HTTP 200 und `responseCode 100108 „Invalid TID“` (belegt an hps 1.10.0),
  ohne Zahlung und ohne Nebenwirkung. `POST /v1/terminal/test` nimmt optional
  eine `tid` und liefert dann die echte Diagnose samt Gerätestatus; die TID
  selbst kann die Suche nicht liefern (sie steht im Vertrag/Panel).

## 1.2.0 — 2026-08-20

- **Terminal-Suche:** `POST /v1/terminal/discover` scannt das Kassen-Netz auf
  Port 8080 (gleiches Verfahren wie die Druckersuche) und fragt jeden offenen
  Kandidaten mit `GET /api/terminals` nach — nur wer mit einer Terminal-Liste
  antwortet, ist ein Treffer (Router-UIs und Kameras lauschen auch auf 8080).
  Liefert Host, Port und TIDs; die Kasse muss die IP nicht mehr am Gerät
  ablesen.

## 1.1.0 — 2026-08-20

- **Kartenterminal (Hobex HPS):** der Agent reicht Terminal-Aufrufe der Kasse
  an das HPS im Kassen-Netz weiter (JSON-REST auf Port 8080; der Browser kann
  das von einer https-Seite aus nicht selbst). Neue, token-geschützte
  Endpunkte: `POST /v1/terminal/test` (Erreichbarkeit, liefert die
  Terminal-Stammdaten samt TID), `…/diagnosis`, `…/payment` (blockiert bis
  zum Ende des Kartenflows, bis zu 4 Minuten; Beträge in Cent, die Brücke
  übersetzt in Euro), `…/status` (Rettungsweg nach Verbindungsabriss) und
  `…/abort`. Eine **Ablehnung** ist keine Störung: sie kommt als `ok:true`
  mit dem HPS-`responseCode` durch — nur Transportfehler werden übersetzt
  (`terminal_offline`, `timeout`, `terminal_error`).

## 1.0.3 — 2026-08-20

- **Kopplung in einem Schritt:** neuer Endpunkt `POST /v1/pair/direct` gibt der
  Kasse den Token direkt in der Antwort zurück — kein Browsersprung auf die
  Kopplungsseite, kein Code. Erreichbar nur für Seiten, deren Herkunft die
  serverseitige Allowlist passiert; Aufrufe ohne Origin-Kopfzeile werden
  abgewiesen (Werkzeuge koppeln weiter über `kasseneck-connect pair`). Teilt
  sich die 10-Sekunden-Drossel mit `POST /v1/pair/request`. Der bisherige
  Code-Weg bleibt vollständig bestehen.
- `tool/notarize_macos.sh`: die Profil-Vorprüfung läuft jetzt über
  `notarytool` selbst — `security find-generic-password` sieht den
  Profileintrag nicht, wodurch 1.0.2 zunächst unnotarisiert veröffentlicht
  wurde (die Assets wurden nachträglich ersetzt).

## 1.0.2 — 2026-08-20

- **Signiert und notarisiert (macOS).** Binary und Installationspaket tragen
  eine Developer-ID-Signatur — Herausgeber **POST NOW e.U.** (Team-ID
  6KMT4H4CNE) — und sind bei Apple notarisiert; das Ticket ist ins Paket
  geheftet. Der Umweg über „Systemeinstellungen → Datenschutz & Sicherheit →
  Dennoch öffnen“ entfällt, das Paket öffnet sich wie jede gekaufte Software.
  Die Binary läuft mit Hardened Runtime.
- `tool/build_macos.sh` und `tool/pkg/macos/build_pkg.sh` signieren, sobald der
  Schlüsselbund die Zertifikate hergibt, und warnen sonst (die CI baut
  weiterhin unsigniert). Neu dazu `tool/notarize_macos.sh`; `tool/release.sh`
  holt die Notarisierung vor dem Veröffentlichen selbst nach.

## 1.0.1 — 2026-08-20

- **Kopplung aus der Kasse anstoßbar.** `POST /v1/pair/request` erzeugt einen
  frischen Kopplungscode und öffnet die Kopplungsseite im Standardbrowser des
  Rechners — die Kasse braucht dafür weder einen Token noch den Umweg über
  `kasseneck-connect pair`. Der Code steht ausschließlich in dem lokal
  geöffneten Fenster, die Antwort ist bloß `{ok: true}`. Höchstens eine
  Anforderung je 10 Sekunden (`pair_request_throttled`).

## 1.0.0 — 2026-08-19

Erste ausgelieferte Fassung: der Agent kann alles, was die Browser-Kasse zum
Drucken braucht.

- **Lokale API und Kopplung.** HTTP-Schnittstelle ausschließlich auf
  `127.0.0.1:27182` (Fallback bis 27189), feste Herkunftsliste und
  Kopplungstoken. Der sechsstellige Code gilt 10 Minuten, nach 5 Fehlversuchen
  ist die Kopplung 60 Sekunden gesperrt; vom Token bleibt nur der SHA-256-Hash
  im Agenten.
- **Netzwerkdrucker.** Bondrucker über TCP 9100 (roher ESC/POS-Strom) und über
  Epson ePOS-Print (HTTP/HTTPS, `devid` je Gerät). Der Agent ist reiner
  Transport — die Bytes entstehen in der Kasse.
- **Druckersuche.** mDNS (3 s) und auf Wunsch ein Portscan **aller** lokalen
  IPv4-Netze (höchstens vier, ein Netz je /24, insgesamt bis 8 s). Die Antwort
  nennt die abgesuchten Netze, damit die Kasse zeigen kann, wo gesucht wurde.
- **Druckwarteschlange.** Seriell je Drucker, 10 s Zeitlimit je Versuch, genau
  eine Wiederholung — und nur, wenn sicher nichts hinausgegangen ist. Derselbe
  `jobId` druckt auf demselben Drucker 60 Sekunden lang kein zweites Mal;
  gemerkt wird nur, was ein zweiter Druck verschlimmern könnte.
- **Ereignisse.** WebSocket `/v1/events` mit `hello`, `printer.state`,
  `print.done` und `print.failed`, Ping alle 30 Sekunden, Token auch als
  Query-Parameter (der Browser kann bei `new WebSocket(…)` keine Kopfzeilen
  setzen).
- **Autostart.** LaunchAgent (macOS), Aufgabenplanung „Bei Anmeldung"
  (Windows) und `systemd --user` (Linux) — eingerichtet und wieder entfernt
  über `install-autostart` / `uninstall-autostart`.
- **Diagnose.** `kasseneck-connect doctor` nennt Version, Pfade, den Port, auf
  dem ein Agent antwortet, die eingetragenen Drucker samt Zustand, den
  Autostart-Zustand und die letzten Fehlerzeilen. Das Log rotiert täglich und
  enthält nie Beleginhalte.
- **Installer.** macOS-`.pkg`, Windows-`.exe` (Inno Setup, ohne
  Administratorrechte nach `%LocalAppData%`) und Linux-`.deb`. Beide
  Signaturen fehlen in dieser Fassung — die Wege an Gatekeeper und SmartScreen
  vorbei stehen in der README.
- **Release-Feed.** `tool/release.sh` lädt die Artefakte nach
  `connect/<version>/` und `connect/latest/` und schreibt `latest.json`
  (Version, SHA-256, Größe je Plattform) als Grundlage des Selbstaustauschs.
