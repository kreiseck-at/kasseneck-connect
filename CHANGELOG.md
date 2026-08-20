# Änderungen

Alle nennenswerten Änderungen an Kasseneck Connect. Die Versionsnummer folgt
[SemVer](https://semver.org/lang/de/); sie steht in `pubspec.yaml` und
`lib/src/version.dart` und wird über `GET /v1/status` sowie im Update-Feed
gemeldet.

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
