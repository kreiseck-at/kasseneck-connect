import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/config_model_1_4_2.dart' as alt;

/// Eine `config.json`, wie Connect 1.4.2 sie schreibt (erfundene Werte).
const String _config142 = '''
{
  "schemaVersion": 1,
  "port": 27182,
  "httpsPort": 27190,
  "tokenHashes": ["aa11", "bb22"],
  "printers": [
    {"id": "p_ab12cd34", "name": "Bon", "kind": "tcp9100",
     "host": "192.168.0.50", "port": 9100}
  ],
  "terminal": {"kind": "hobex", "host": "192.168.0.60", "port": 8080},
  "updateChannel": "stable",
  "allowDevOrigins": false,
  "bluetoothDevices": []
}
''';

void main() {
  late Directory temp;
  late ConfigStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-rueckwaerts-');
    store = ConfigStore.forDirectory(temp);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('alte config.json (1.4.x)', () {
    test('lädt vollständig, ohne Kennung, alle Neuerungen an', () async {
      File(p.join(temp.path, 'config.json')).writeAsStringSync(_config142);
      final config = await store.load();

      expect(config.tokenHashes, <String>['aa11', 'bb22']);
      expect(config.printers.single.host, '192.168.0.50');
      expect(config.printers.single.hatKennung, isFalse);
      expect(config.terminal?.host, '192.168.0.60');
      expect(config.terminal?.confirmedAt, isNull);
      expect(config.installationId, isNull);
      expect(config.relocations, isEmpty);
      for (final neuerung in Neuerung.values) {
        expect(config.aktiv(neuerung), isTrue, reason: neuerung.wireName);
      }
    });

    test('kaputte config.json mit .bak aus 1.4.2: die Sicherung springt ein '
        'und behält ihre Felder', () async {
      File(p.join(temp.path, 'config.json')).writeAsStringSync('{kaputt');
      File(p.join(temp.path, 'config.json.bak')).writeAsStringSync(_config142);

      final config = await store.load();
      expect(config.tokenHashes, <String>['aa11', 'bb22']);
      expect(config.printers.single.id, 'p_ab12cd34');
    });
  });

  group('von 1.5.0 geschrieben, von 1.4.2 gelesen', () {
    test('der Lader aus 1.4.2 liest Kopplung, Drucker und Terminal', () async {
      File(p.join(temp.path, 'config.json')).writeAsStringSync(_config142);
      await sichereInstallationId(store);
      await store.mutate(
        (c) => c
            .copyWith(
              printers: <PrinterConfig>[
                c.printers.single.copyWith(
                  model: 'TM-m30III',
                  serial: 'X5ZT000123',
                  mac: '00:26:ab:00:00:01',
                  identifiedAt: DateTime.utc(2026, 11, 10, 9),
                  identitySource: KennungsQuelle.escpos,
                ),
              ],
              terminal: c.terminal!.copyWith(
                tid: '12345678',
                mac: '00:26:ab:00:00:02',
                confirmedAt: DateTime.utc(2026, 11, 10, 9),
              ),
              disabledFeatures: <String>['status_poll'],
            )
            .mitAdressWechsel(
              AdressWechsel(
                at: DateTime.utc(2026, 11, 10, 9),
                art: GeraeteArt.drucker,
                kennung: 'p_ab12cd34',
                von: '192.168.0.49:9100',
                nach: '192.168.0.50:9100',
              ),
            ),
      );

      final roh = jsonDecode(
        File(p.join(temp.path, 'config.json')).readAsStringSync(),
      );
      final gelesen = alt.AgentConfig.fromJson(alt.readMap(roh)!);

      expect(gelesen.tokenHashes, <String>['aa11', 'bb22']);
      expect(gelesen.printers.single.id, 'p_ab12cd34');
      expect(gelesen.printers.single.host, '192.168.0.50');
      expect(gelesen.printers.single.port, 9100);
      expect(gelesen.printers.single.kind, alt.PrinterKind.tcp9100);
      expect(gelesen.terminal?.host, '192.168.0.60');
      expect(gelesen.terminal?.tid, '12345678');
      expect(gelesen.port, 27182);
    });
  });

  group('unbekannte Felder überleben das Schreiben', () {
    test('oben, je Drucker und am Terminal', () async {
      File(p.join(temp.path, 'config.json')).writeAsStringSync('''
{
  "port": 27182,
  "zukunft": {"a": 1},
  "printers": [
    {"id": "p1", "name": "Bon", "kind": "tcp9100", "host": "192.168.0.50",
     "port": 9100, "papierRolle": "lang"}
  ],
  "terminal": {"kind": "hobex", "host": "192.168.0.60", "port": 8080,
               "firmware": "7.3.6"},
  "disabledFeatures": ["status_poll", "kommt_erst_spaeter"]
}
''');
      await store.mutate((c) => c.copyWith(updateChannel: 'beta'));

      final roh =
          jsonDecode(File(p.join(temp.path, 'config.json')).readAsStringSync())
              as Map<String, Object?>;
      expect(roh['zukunft'], <String, Object?>{'a': 1});
      expect(
        (roh['printers']! as List<Object?>).single,
        containsPair('papierRolle', 'lang'),
      );
      expect(roh['terminal'], containsPair('firmware', '7.3.6'));
      expect(roh['disabledFeatures'], <String>[
        'status_poll',
        'kommt_erst_spaeter',
      ]);
      expect(roh['updateChannel'], 'beta');
    });

    test('bekannte Felder gewinnen gegen gleichnamige Fremdfelder', () {
      final config = AgentConfig.fromJson(<String, Object?>{
        'port': 27183,
        'zukunft': true,
      });
      expect(config.toJson()['port'], 27183);
      expect(config.extras.keys, <String>['zukunft']);
    });
  });
}
