# Änderungen

Alle nennenswerten Änderungen an Kasseneck Connect. Die Versionsnummer folgt
[SemVer](https://semver.org/lang/de/); sie steht in `pubspec.yaml` und
`lib/src/version.dart` und wird über `GET /v1/status` sowie im Update-Feed
gemeldet.

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
