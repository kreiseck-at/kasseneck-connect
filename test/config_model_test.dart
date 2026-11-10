import 'dart:convert';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

void main() {
  group('AgentConfig', () {
    test('Standardwerte', () {
      final config = AgentConfig();
      expect(config.schemaVersion, currentSchemaVersion);
      expect(config.port, 27182);
      expect(config.tokenHashes, isEmpty);
      expect(config.printers, isEmpty);
      expect(config.terminal, isNull);
      expect(config.updateChannel, 'stable');
    });

    test('JSON-Roundtrip erhält alle Felder', () {
      final original = AgentConfig(
        port: 27183,
        tokenHashes: <String>['aa11', 'bb22'],
        printers: <PrinterConfig>[
          PrinterConfig(
            id: 'p1',
            name: 'Bon',
            kind: PrinterKind.tcp9100,
            host: '192.168.0.20',
          ),
          PrinterConfig(
            id: 'p2',
            name: 'ePOS',
            kind: PrinterKind.epos,
            host: 'drucker.local',
            port: 443,
            devid: 'local_printer',
          ),
        ],
        terminal: TerminalConfig(host: '192.168.0.30', port: 8080, tid: 'T1'),
        updateChannel: 'stable',
      );

      final decoded = jsonDecode(jsonEncode(original.toJson())) as Object?;
      final copy = AgentConfig.fromJson(readMap(decoded)!);

      expect(copy.port, 27183);
      expect(copy.tokenHashes, <String>['aa11', 'bb22']);
      expect(copy.printers, hasLength(2));
      expect(copy.printers[0].kind, PrinterKind.tcp9100);
      expect(copy.printers[0].port, 9100, reason: 'Standardport der Anbindung');
      expect(copy.printers[1].kind, PrinterKind.epos);
      expect(copy.printers[1].port, 443);
      expect(copy.printers[1].devid, 'local_printer');
      expect(copy.terminal?.host, '192.168.0.30');
      expect(copy.terminal?.tid, 'T1');
    });

    test('fromJson ist tolerant gegen fehlende und falsche Felder', () {
      final config = AgentConfig.fromJson(<String, Object?>{
        'port': '27185',
        'tokenHashes': <Object?>['ok', 42, null],
        'printers': <Object?>[
          <String, Object?>{
            'id': 'p1',
            'kind': 'unbekannt',
            'host': '10.0.0.5',
          },
          'kaputt',
        ],
        'terminal': 'kaputt',
      });

      expect(config.schemaVersion, currentSchemaVersion);
      expect(config.port, 27185, reason: 'numerischer String wird gelesen');
      expect(config.tokenHashes, <String>['ok']);
      expect(config.printers, hasLength(1));
      expect(config.printers.single.kind, PrinterKind.tcp9100);
      expect(config.printers.single.name, '');
      expect(config.terminal, isNull);
      expect(config.updateChannel, 'stable');
    });

    test('leeres JSON ergibt die Standardkonfiguration', () {
      final config = AgentConfig.fromJson(<String, Object?>{});
      expect(config.port, 27182);
      expect(config.printers, isEmpty);
    });

    test('copyWith kann das Terminal löschen', () {
      final config = AgentConfig(terminal: TerminalConfig(host: '10.0.0.1'));
      expect(config.copyWith(port: 27184).terminal, isNotNull);
      expect(config.copyWith(clearTerminal: true).terminal, isNull);
      expect(config.copyWith(port: 27184).port, 27184);
    });

    test('Listen sind unveränderlich', () {
      final config = AgentConfig(tokenHashes: <String>['a']);
      expect(() => config.tokenHashes.add('b'), throwsUnsupportedError);
      expect(() => config.printers.clear(), throwsUnsupportedError);
    });
  });

  group('Port aus der Datei', () {
    test('0 wird auf den Standardport normalisiert', () {
      expect(
        AgentConfig.fromJson(<String, Object?>{'port': 0}).port,
        defaultAgentPort,
      );
    });

    test('Unsinn wird auf den Standardport normalisiert', () {
      for (final value in <Object?>[-1, 70000, 'abc', null]) {
        expect(
          AgentConfig.fromJson(<String, Object?>{'port': value}).port,
          defaultAgentPort,
          reason: '$value',
        );
      }
    });

    test('ein echter Port bleibt stehen', () {
      expect(
        AgentConfig.fromJson(<String, Object?>{'port': 27185}).port,
        27185,
      );
    });

    test('programmatisch bleibt 0 erlaubt (freier Port im Test)', () {
      expect(AgentConfig(port: 0).port, 0);
    });
  });

  group('HTTPS-Port', () {
    test('Standard 27190, getrennt vom HTTP-Port', () {
      expect(defaultHttpsPort, 27190);
      expect(AgentConfig().httpsPort, 27190);
      expect(AgentConfig.fromJson(<String, Object?>{}).httpsPort, 27190);
    });

    test('Roundtrip und copyWith', () {
      final config = AgentConfig(httpsPort: 27192);
      final copy = AgentConfig.fromJson(
        readMap(jsonDecode(jsonEncode(config.toJson())))!,
      );
      expect(copy.httpsPort, 27192);
      expect(copy.port, defaultAgentPort);
      expect(config.copyWith(port: 27183).httpsPort, 27192);
      expect(config.copyWith(httpsPort: 27191).httpsPort, 27191);
    });

    test('tolerant wie port: Unsinn ergibt den Standard', () {
      expect(
        AgentConfig.fromJson(<String, Object?>{'httpsPort': '27193'}).httpsPort,
        27193,
      );
      for (final value in <Object?>[0, -1, 70000, 'abc', null, true]) {
        expect(
          AgentConfig.fromJson(<String, Object?>{'httpsPort': value}).httpsPort,
          defaultHttpsPort,
          reason: '$value',
        );
      }
    });
  });

  group('allowDevOrigins', () {
    test('ist standardmäßig aus und überlebt den Roundtrip', () {
      expect(AgentConfig().allowDevOrigins, isFalse);
      final config = AgentConfig(allowDevOrigins: true);
      expect(AgentConfig.fromJson(config.toJson()).allowDevOrigins, isTrue);
    });

    test('nur echtes true schaltet frei', () {
      for (final value in <Object?>['true', 1, null]) {
        expect(
          AgentConfig.fromJson(<String, Object?>{
            'allowDevOrigins': value,
          }).allowDevOrigins,
          isFalse,
          reason: '$value',
        );
      }
    });

    group('bluetoothDevices', () {
      const idA = '1a2b3c4d-0000-4000-8000-00805f9b34fb';
      const idB = '9f8e7d6c-1111-4222-8333-444455556666';

      test('Standard leer, unveränderlich', () {
        final config = AgentConfig();
        expect(config.bluetoothDevices, isEmpty);
        expect(
          () => config.bluetoothDevices.add(
            BluetoothDeviceConfig(
              id: idA,
              name: 'x',
              approvedAt: DateTime.utc(2026),
            ),
          ),
          throwsUnsupportedError,
        );
      });

      test('Rundlauf mit zwei Geräten', () {
        final original = AgentConfig(
          bluetoothDevices: <BluetoothDeviceConfig>[
            BluetoothDeviceConfig(
              id: idA,
              name: 'Q199E00000',
              approvedAt: DateTime.utc(2026, 10, 28, 9, 30),
            ),
            BluetoothDeviceConfig(
              id: idB,
              name: 'Waage Theke',
              approvedAt: DateTime.utc(2026, 10, 29, 7),
            ),
          ],
        );
        final json = jsonDecode(jsonEncode(original.toJson()));
        expect((json as Map)['bluetoothDevices'], hasLength(2));
        final restored = AgentConfig.fromJson(json.cast<String, Object?>());
        expect(restored.bluetoothDevices, hasLength(2));
        expect(restored.bluetoothDevices[0].id, idA);
        expect(restored.bluetoothDevices[0].name, 'Q199E00000');
        expect(
          restored.bluetoothDevices[0].approvedAt,
          DateTime.utc(2026, 10, 28, 9, 30),
        );
        expect(restored.bluetoothDevices[1].id, idB);
        expect(restored.bluetoothDevices[1].approvedAt.isUtc, isTrue);
      });

      test('alte config.json ohne Feld lädt mit leerer Liste', () {
        final config = AgentConfig.fromJson(<String, Object?>{'port': 27182});
        expect(config.bluetoothDevices, isEmpty);
      });

      test('kaputte Einträge werden übersprungen', () {
        final config = AgentConfig.fromJson(<String, Object?>{
          'bluetoothDevices': <Object?>[
            <String, Object?>{
              'id': 'kaputt',
              'name': 'A',
              'approvedAt': '2026-10-28T09:30:00Z',
            },
            <String, Object?>{'id': idA, 'name': 'B'},
            <String, Object?>{'id': idA, 'name': 'C', 'approvedAt': 'gestern'},
            'Unsinn',
            <String, Object?>{
              'id': idB.toUpperCase(),
              'name': 'Gut',
              'approvedAt': '2026-10-28T09:30:00Z',
            },
          ],
        });
        expect(config.bluetoothDevices, hasLength(1));
        expect(config.bluetoothDevices.single.id, idB);
        expect(config.bluetoothDevices.single.name, 'Gut');
      });

      test('fehlender oder leerer Name fällt auf die Kennung zurück', () {
        final config = AgentConfig.fromJson(<String, Object?>{
          'bluetoothDevices': <Object?>[
            <String, Object?>{'id': idA, 'approvedAt': '2026-10-28T09:30:00Z'},
            <String, Object?>{
              'id': idB,
              'name': '',
              'approvedAt': '2026-10-28T09:30:00Z',
            },
          ],
        });
        expect(config.bluetoothDevices.map((d) => d.name), <String>[idA, idB]);
      });

      test('Kennung wird kleingeschrieben gespeichert', () {
        final device = BluetoothDeviceConfig(
          id: idA.toUpperCase(),
          name: 'x',
          approvedAt: DateTime.utc(2026),
        );
        expect(device.id, idA);
        expect(device.toJson()['id'], idA);
      });

      test('copyWith ändert nur die Geräteliste', () {
        final base = AgentConfig(
          port: 27184,
          tokenHashes: <String>['aa'],
          allowDevOrigins: true,
        );
        final copy = base.copyWith(
          bluetoothDevices: <BluetoothDeviceConfig>[
            BluetoothDeviceConfig(
              id: idA,
              name: 'x',
              approvedAt: DateTime.utc(2026),
            ),
          ],
        );
        expect(copy.bluetoothDevices, hasLength(1));
        expect(copy.port, 27184);
        expect(copy.tokenHashes, <String>['aa']);
        expect(copy.allowDevOrigins, isTrue);
        expect(copy.schemaVersion, 1);
        expect(base.copyWith().bluetoothDevices, isEmpty);
      });
    });
  });

  group('Kennung, Adresswechsel, Schalter (ab 1.5.0)', () {
    test('MAC-Schreibweisen werden einheitlich, Unsinn fällt weg', () {
      const faelle = <String?, String?>{
        '0:26:ab:0:0:1': '00:26:ab:00:00:01',
        '00-26-AB-00-00-01': '00:26:ab:00:00:01',
        '00:26:ab:00:00:01': '00:26:ab:00:00:01',
        ' 00:26:ab:00:00:01 ': '00:26:ab:00:00:01',
        'ff:ff:ff:ff:ff:ff': null,
        '0:0:0:0:0:0': null,
        '(incomplete)': null,
        '00:26:ab:00:00': null,
        '00:26:ab:00:00:01:02': null,
        '00:26:ab:00:00:0g': null,
        '000:26:ab:00:00:01': null,
        null: null,
      };
      faelle.forEach((roh, erwartet) {
        expect(normalizeMac(roh), erwartet, reason: '$roh');
      });
    });

    test('Kennung am Drucker übersteht den Rundlauf', () {
      final drucker = PrinterConfig(
        id: 'p1',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
        model: 'TM-m30III',
        serial: 'X5ZT000123',
        mac: '00:26:ab:00:00:01',
        identifiedAt: DateTime.utc(2026, 11, 10, 9),
        identitySource: KennungsQuelle.escpos,
      );
      final kopie = PrinterConfig.fromJson(
        readMap(jsonDecode(jsonEncode(drucker.toJson())))!,
      );
      expect(kopie.model, 'TM-m30III');
      expect(kopie.serial, 'X5ZT000123');
      expect(kopie.mac, '00:26:ab:00:00:01');
      expect(kopie.identifiedAt, DateTime.utc(2026, 11, 10, 9));
      expect(kopie.identitySource, KennungsQuelle.escpos);
      expect(kopie.hatKennung, isTrue);
      expect(kopie.ohneKennung().hatKennung, isFalse);
      expect(kopie.ohneKennung().model, isNull);
    });

    test('die API-Form eines Druckers bleibt die von 1.4.2', () {
      final drucker = PrinterConfig(
        id: 'p1',
        name: 'Bon',
        kind: PrinterKind.epos,
        host: '192.168.0.50',
        devid: 'local_printer',
        serial: 'X5ZT000123',
        extras: const <String, Object?>{'zukunft': 1},
      );
      expect(drucker.toApiJson().keys, <String>[
        'id',
        'name',
        'kind',
        'host',
        'port',
        'devid',
      ]);
    });

    test('überlange oder leere Kennungstexte werden nicht gespeichert', () {
      final drucker = PrinterConfig.fromJson(<String, Object?>{
        'id': 'p1',
        'kind': 'tcp9100',
        'host': '192.168.0.50',
        'model': '',
        'serial': 'X' * (kennungsTextMaxLength + 1),
        'mac': 'kaputt',
        'identitySource': 'unbekannt',
      });
      expect(drucker.model, isNull);
      expect(drucker.serial, isNull);
      expect(drucker.mac, isNull);
      expect(drucker.identitySource, isNull);
    });

    test('Terminal mit TID, MAC und Bestätigung übersteht den Rundlauf', () {
      final terminal = TerminalConfig(
        host: '192.168.0.60',
        tid: '12345678',
        mac: '00:26:ab:00:00:02',
        confirmedAt: DateTime.utc(2026, 11, 10, 9),
      );
      final kopie = TerminalConfig.fromJson(
        readMap(jsonDecode(jsonEncode(terminal.toJson())))!,
      );
      expect(kopie.tid, '12345678');
      expect(kopie.mac, '00:26:ab:00:00:02');
      expect(kopie.confirmedAt, DateTime.utc(2026, 11, 10, 9));
    });

    test('Adresswechsel: höchstens die letzten 20, kaputte fallen weg', () {
      var config = AgentConfig();
      for (var i = 0; i < 25; i++) {
        config = config.mitAdressWechsel(
          AdressWechsel(
            at: DateTime.utc(2026, 11, 10, 9, i),
            art: i.isEven ? GeraeteArt.drucker : GeraeteArt.terminal,
            kennung: i.isEven ? 'p_$i' : '12345678',
            von: '192.168.0.50:9100',
            nach: '192.168.0.61:9100',
          ),
        );
      }
      expect(config.relocations, hasLength(adressWechselLimit));
      expect(config.relocations.first.at, DateTime.utc(2026, 11, 10, 9, 5));

      final roh = config.toJson();
      final liste = (roh['relocations']! as List<Object?>).toList()
        ..add(<String, Object?>{'art': 'printer'})
        ..add(<String, Object?>{
          'at': '2026-11-10T09:00:00Z',
          'art': 'terminal',
          'von': 'a',
          'nach': 'b',
        });
      final kopie = AgentConfig.fromJson(<String, Object?>{
        ...roh,
        'relocations': liste,
      });
      expect(kopie.relocations, hasLength(adressWechselLimit));
      expect(kopie.relocations.last.kennung, 'p_24');
      expect(kopie.relocations.first.toJson()['tid'], '12345678');
      expect(kopie.relocations[1].toJson()['id'], 'p_6');
    });

    test('Schalter: Vorgabe an, abgeschaltet nur, was genannt ist', () {
      final config = AgentConfig.fromJson(<String, Object?>{
        'disabledFeatures': <Object?>['printer_status', 42, 'unbekannt'],
      });
      expect(config.aktiv(Neuerung.druckerStatus), isFalse);
      expect(config.aktiv(Neuerung.druckerKennung), isTrue);
      expect(config.disabledFeatures, <String>['printer_status', 'unbekannt']);
      expect(Neuerung.fromWireName('sleep_lock'), Neuerung.schlafsperre);
      expect(Neuerung.fromWireName('gibt_es_nicht'), isNull);
      expect(AgentConfig().toJson().containsKey('disabledFeatures'), isFalse);
    });
  });
}
