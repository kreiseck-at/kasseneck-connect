# Protokoll Agent und Bluetooth-Hilfsprogramm

Der Agent startet das Hilfsprogramm (CoreBluetooth) als Kindprozess und spricht über stdin/stdout.
Eine Zeile ist genau ein JSON-Objekt, UTF-8, Zeilenende `\n`. Unbekannte Zusatzfelder werden ignoriert,
Zeilen, die kein gültiges Objekt sind, ebenfalls (nie abstürzen). Meldungen auf stderr sind nur fürs Protokoll.

Dart-Seite: `lib/src/bluetooth/protocol.dart`. Beispielzeilen für beide Seiten:
`test/fixtures/bluetooth_protokoll_beispiele.jsonl` (je Zeile `Name<Tab>Zeile`).

## Form

- Befehl (Agent an Hilfsprogramm): `{"id":n,"op":"…","args":{…}}`
- Antwort ok: `{"id":n,"ok":true,"result":{…}}`
- Antwort mit Fehler: `{"id":n,"ok":false,"error":{"code":"…","message":"…"}}`
- Ereignis (ungefragt, ohne `id`): `{"event":"…", …Felder…}`

Jede Antwort trägt die `id` ihres Befehls. Der Nutzinhalt heißt `result` (nicht `data`), damit er nicht mit dem
Base64-Feld `data` von `read` zusammenstößt. Bytes sind immer Base64 im Feld `data`. Geräte-IDs sind
CoreBluetooth-UUIDs in Kleinschreibung, UUIDs von Dienst und Merkmal in der kurzen oder langen Form. Das
macOS-Hilfsprogramm schreibt sie immer lang und klein (`0000ff00-0000-1000-8000-00805f9b34fb`).

## Befehle (`op`)

| op | args | result |
|---|---|---|
| `ping` | – | `{}` |
| `state` | – | `{"state":"poweredOn"}` |
| `scan` | `ms` (1 bis 3 600 000) | `{}` (Funde kommen als Ereignis `discovered`, Scan endet nach `ms`) |
| `stopScan` | – | `{}` |
| `connect` | `device` | `{}` (das Ereignis `connected` kommt unmittelbar davor) |
| `disconnect` | `device` | `{}` |
| `gatt` | `device` | `{"services":[{"uuid","characteristics":[{"uuid","properties":[…]}]}]}` |
| `read` | `device`, `service`, `characteristic` | `{"data":"<Base64>"}` |
| `write` | `device`, `service`, `characteristic`, `data`, `withResponse` | `{}` |
| `subscribe` / `unsubscribe` | `device`, `service`, `characteristic` | `{}` |

## Ereignisse (`event`)

- `state {state}`: `unknown`, `resetting`, `unsupported`, `unauthorized`, `poweredOff`, `poweredOn`
- `discovered {device, name, rssi, services[]}`
- `connected {device, maxWriteWithResponse, maxWriteWithoutResponse}`
- `disconnected {device, reason}`
- `notification {device, service, characteristic, data}`

## Fehlercodes des Hilfsprogramms

`unknown_device`, `not_connected`, `unknown_characteristic`, `unsupported_operation`, `write_failed`,
`read_failed`, `bluetooth_off`, `unauthorized`, `bluetooth_unsupported`, `bad_request`. Der `message`-Text ist nur
fürs Protokoll; Klartext für Nutzer erzeugt später die Brücke im Agenten.

## Verhalten des Hilfsprogramms

Das Hilfsprogramm übersetzt nur; es verbindet nie von selbst neu und hat keine eigenen Zeitlimits.

- **Start und Zustand.** `ping` antwortet immer sofort und berührt Bluetooth nicht. Erst der erste andere Befehl legt
  den CoreBluetooth-Zugang an (und löst beim ersten Mal die Freigabe aus). Jede Zustandsänderung kommt als Ereignis
  `state`. Solange der Zustand `unknown` oder `resetting` ist, warten Befehle (auch `state`); danach antwortet `state`
  mit dem Zustand, `stopScan` und `disconnect` mit `{}`, alle anderen laufen bei `poweredOn` und bekommen sonst
  `bluetooth_off` (`poweredOff`), `unauthorized` bzw. `bluetooth_unsupported`.
- **Suche.** Ohne Dienstfilter. `discovered` kommt je Gerät und Suche einmal (Name aus der Werbung, sonst der
  Gerätename, sonst `null`; kommt der Name erst später, folgt genau ein weiteres `discovered`). Die Antwort auf `scan`
  kommt, wenn das Fenster endet oder `stopScan` bzw. ein neues `scan` es vorzeitig beendet; geht Bluetooth dabei aus,
  kommt der Fehler des Zustands.
- **Verbinden.** Kennt der Mac die Kennung nicht, sofort `unknown_device`. Sonst kommt die Antwort, sobald verbunden
  und alle Dienste und Merkmale gelesen sind; ein schon verbundenes Gerät meldet `connected` erneut. CoreBluetooth
  wartet ohne Ende; abbrechen kann der Agent mit `disconnect` – das offene `connect` bekommt dann `not_connected`.
- **Trennen.** `disconnect` antwortet, wenn CoreBluetooth das Trennen meldet (nicht verbunden: sofort `{}`). Befehle
  für ein Gerät, das gerade getrennt wird, laufen erst danach. Geht eine Verbindung verloren (Gerät weg, Bluetooth
  aus), kommt `disconnected` (nur nach einem `connected`), und jeder offene Befehl des Geräts bekommt `not_connected`.
- **Schreiben.** Fehlt dem Merkmal die gewählte Schreibart, `unsupported_operation`. Länger als `maxWriteWithResponse`
  bzw. `maxWriteWithoutResponse`: `write_failed`, nichts wird geschrieben (nie gekürzt). Mit Antwort kommt `{}` nach
  der Bestätigung des Geräts, ohne Antwort sobald CoreBluetooth die Daten nach seiner Flusssteuerung übernommen hat.
- **Lesen und Abo.** Ein offenes `read` nimmt den nächsten Wert des Merkmals; der kommt nicht zusätzlich als
  `notification`. `subscribe`/`unsubscribe` antworten nach der Bestätigung; scheitert sie, `write_failed`.
- **Ungültige Zeilen.** Ein JSON-Objekt mit ganzzahliger `id`, das kein gültiger Befehl ist (auch unbekanntes `op`),
  bekommt `bad_request`; alles andere wird mit einer Notiz auf stderr verworfen. Endet stdin, endet das Programm.

## Beispiele

Die Zeilen stehen wörtlich in der Beispieldatei und werden von den Dart-Tests (und den Swift-Tests) gelesen.
Die ersten vier Gruppen sind gültig, `invalid.*` ergibt beim Lesen `null`.

```
request.ping {"id":1,"op":"ping","args":{}}
request.state {"id":2,"op":"state","args":{}}
request.scan {"id":3,"op":"scan","args":{"ms":5000}}
request.stopScan {"id":4,"op":"stopScan","args":{}}
request.connect {"id":5,"op":"connect","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b"}}
request.disconnect {"id":6,"op":"disconnect","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b"}}
request.gatt {"id":7,"op":"gatt","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b"}}
request.read {"id":8,"op":"read","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","service":"ff00","characteristic":"ff03"}}
request.write {"id":9,"op":"write","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","service":"ff00","characteristic":"ff02","data":"AQE=","withResponse":false}}
request.subscribe {"id":10,"op":"subscribe","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","service":"ff00","characteristic":"ff03"}}
request.unsubscribe {"id":11,"op":"unsubscribe","args":{"device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","service":"ff00","characteristic":"ff03"}}
response.ok {"id":1,"ok":true,"result":{}}
response.okRead {"id":8,"ok":true,"result":{"data":"AgK2AA=="}}
response.error {"id":9,"ok":false,"error":{"code":"not_connected","message":"peripheral is not connected"}}
response.okGatt {"id":7,"ok":true,"result":{"services":[{"uuid":"0000ff00-0000-1000-8000-00805f9b34fb","characteristics":[{"uuid":"0000ff01-0000-1000-8000-00805f9b34fb","properties":["read"]},{"uuid":"0000ff02-0000-1000-8000-00805f9b34fb","properties":["write","writeWithoutResponse"]},{"uuid":"0000ff03-0000-1000-8000-00805f9b34fb","properties":["notify"]}]}]}}
event.state {"event":"state","state":"poweredOn"}
event.discovered {"event":"discovered","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","name":"Q199E00000","rssi":-58,"services":["ff00"]}
event.discoveredUnnamed {"event":"discovered","device":"7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f","name":null,"rssi":-80,"services":[]}
event.connected {"event":"connected","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","maxWriteWithResponse":512,"maxWriteWithoutResponse":20}
event.disconnected {"event":"disconnected","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","reason":"peripheral disconnected"}
event.notification {"event":"notification","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","service":"ff00","characteristic":"ff03","data":"AQE="}
```

Ungültig (werden verworfen): abgeschnittenes Objekt `{"id":1`, leere Zeile, `[]`, `{"foo":1}`.
