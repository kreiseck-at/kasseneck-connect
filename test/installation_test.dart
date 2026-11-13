import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ConfigStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-installation-');
    store = ConfigStore.forDirectory(temp);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('neueInstallationId', () {
    test('ist eine UUID v4 (Version 4, Variante 10xx)', () {
      final random = Random(1);
      for (var i = 0; i < 200; i++) {
        final id = neueInstallationId(random);
        expect(isInstallationId(id), isTrue, reason: id);
        expect(id[14], '4', reason: 'Versionsfeld');
        expect('89ab'.contains(id[19]), isTrue, reason: 'Variante: $id');
        expect(id, id.toLowerCase());
      }
    });

    test('zwei Kennungen unterscheiden sich', () {
      final random = Random.secure();
      expect(neueInstallationId(random), isNot(neueInstallationId(random)));
    });
  });

  group('sichereInstallationId', () {
    test('legt beim ersten Mal an und bleibt dann gleich', () async {
      final erste = await sichereInstallationId(store, random: Random(2));
      final zweite = await sichereInstallationId(store, random: Random(3));
      expect(zweite, erste);
      // Ein neuer Prozess (neuer Store auf derselben Datei) liest dieselbe.
      final andererStore = ConfigStore.forDirectory(temp);
      expect(await sichereInstallationId(andererStore), erste);
    });

    // Ein Prozess hat genau einen Store; dessen Warteschlange ordnet die
    // Aufrufe. Zwei Prozesse ordnet die Dateisperre von mutate (siehe
    // config_concurrency_test) – innerhalb eines Prozesses greift sie nicht.
    test('gleichzeitige Aufrufe ergeben dieselbe Kennung', () async {
      final ids = await Future.wait(<Future<String>>[
        for (var i = 0; i < 5; i++) sichereInstallationId(store),
      ]);
      expect(ids.toSet(), hasLength(1));
    });

    test('eine verdorbene Kennung in der Datei wird ersetzt', () async {
      File(
        p.join(temp.path, 'config.json'),
      ).writeAsStringSync(jsonEncode(<String, Object?>{'installationId': 42}));
      final id = await sichereInstallationId(store);
      expect(isInstallationId(id), isTrue);

      File(p.join(temp.path, 'config.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{'installationId': 'kein-uuid'}),
      );
      final ersatz = await sichereInstallationId(store);
      expect(ersatz, isNot('kein-uuid'));
    });
  });

  group('zweite Ablage installation-id', () {
    File datei() => File(p.join(temp.path, 'installation-id'));

    test('steht nach dem ersten Start auch in installation-id', () async {
      final id = await sichereInstallationId(store, random: Random(4));
      expect(datei().readAsStringSync().trim(), id);
    });

    test('schreibt eine ältere Version die config.json ohne Kennung, kommt '
        'sie aus installation-id zurück', () async {
      final id = await sichereInstallationId(store, random: Random(5));
      // So sähe eine von 1.4.2 neu geschriebene config.json aus.
      File(
        p.join(temp.path, 'config.json'),
      ).writeAsStringSync(jsonEncode(<String, Object?>{'port': 47120}));
      expect(await sichereInstallationId(store, random: Random(6)), id);
      expect((await store.load()).installationId, id);
    });

    test(
      'eine verdorbene installation-id zählt nicht und wird ersetzt',
      () async {
        datei().writeAsStringSync('kein-uuid\n');
        final id = await sichereInstallationId(store, random: Random(7));
        expect(isInstallationId(id), isTrue);
        expect(datei().readAsStringSync().trim(), id);
      },
    );

    test('nichts lesbar oder schreibbar: eine Kennung für diesen Lauf, der '
        'Start scheitert nie', () async {
      // Der Datenordner ist eine Datei: weder config.json noch
      // installation-id lassen sich anlegen.
      final kaputt = File(p.join(temp.path, 'kein-ordner'))
        ..writeAsStringSync('');
      final verdorben = ConfigStore.forDirectory(Directory(kaputt.path));
      final log = AgentLog(Directory(p.join(temp.path, 'logs')));
      final id = await sichereInstallationId(verdorben, log: log);
      expect(isInstallationId(id), isTrue);
      expect(log.file.readAsStringSync(), contains('für diesen Lauf $id'));
    });
  });

  group('Agent', () {
    test(
      'Status ohne Token nennt die Kennung, über Neustarts gleich',
      () async {
        final log = AgentLog(Directory(p.join(temp.path, 'logs')));
        Future<String?> kennungNachStart() async {
          final agent = Agent(
            store: store,
            log: log,
            preferredPort: 0,
            openBrowser: false,
            environment: const <String, String>{},
          );
          await agent.start();
          try {
            final client = HttpClient();
            try {
              final request = await client.getUrl(
                Uri.parse('http://127.0.0.1:${agent.port}/v1/status'),
              );
              final response = await request.close();
              final body =
                  jsonDecode(await response.transform(utf8.decoder).join())
                      as Map<String, Object?>;
              expect(body['ok'], isTrue);
              expect(body.containsKey('printers'), isFalse, reason: 'Kurzform');
              return body['installationId'] as String?;
            } finally {
              client.close(force: true);
            }
          } finally {
            await agent.stop();
          }
        }

        final erste = await kennungNachStart();
        expect(erste, isNotNull);
        expect(isInstallationId(erste!), isTrue);
        expect(await kennungNachStart(), erste);
      },
    );
  });
}
