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
CoreBluetooth-UUIDs in Kleinschreibung, UUIDs von Dienst und Merkmal in der kurzen oder langen Form.

## Befehle (`op`)

| op | args | result |
|---|---|---|
| `ping` | – | `{}` |
| `state` | – | `{"state":"poweredOn"}` |
| `scan` | `ms` | `{}` (Funde kommen als Ereignis `discovered`, Scan endet nach `ms`) |
| `stopScan` | – | `{}` |
| `connect` | `device` | `{}` (danach Ereignis `connected`) |
| `disconnect` | `device` | `{}` |
| `gatt` | `device` | Dienste und Merkmale des verbundenen Geräts |
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
`read_failed`, `bluetooth_off`, `unauthorized`, `bad_request`. Der `message`-Text ist nur fürs Protokoll;
Klartext für Nutzer erzeugt später die Brücke im Agenten.

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
event.state {"event":"state","state":"poweredOn"}
event.discovered {"event":"discovered","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","name":"Q199E00000","rssi":-58,"services":["ff00"]}
event.connected {"event":"connected","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","maxWriteWithResponse":512,"maxWriteWithoutResponse":20}
event.disconnected {"event":"disconnected","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","reason":"peripheral disconnected"}
event.notification {"event":"notification","device":"3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b","service":"ff00","characteristic":"ff03","data":"AQE="}
```

Ungültig (werden verworfen): abgeschnittenes Objekt `{"id":1`, leere Zeile, `[]`, `{"foo":1}`.
