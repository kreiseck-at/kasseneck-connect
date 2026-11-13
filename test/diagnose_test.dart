import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/fake_process_runner.dart';

void main() {
  group('Positivliste (rein)', () {
    test('nennt nur, was dort steht – nie Tokens, Kopplung, Fremdfelder', () {
      final config = AgentConfig.fromJson(<String, Object?>{
        'installationId': '0b9d6a2c-1c4e-4f8a-9d3b-2a7c5e8f1b40',
        'tokenHashes': <String>['geheimer-hash'],
        'pairing': <String, Object?>{'code': '987650'},
        'zukunftsGeheimnis': 'nie zeigen',
        'printers': <Object?>[
          <String, Object?>{
            'id': 'p_ab12cd34',
            'name': 'Bon',
            'kind': 'tcp9100',
            'host': '192.168.0.50',
            'port': 9100,
            'serial': 'X5ZT000123',
            'mac': '00:26:ab:00:00:01',
            'zugangsdaten': 'nie zeigen',
          },
        ],
        'terminal': <String, Object?>{
          'host': '192.168.0.60',
          'port': 8080,
          'tid': '12345678',
          'apiSchluessel': 'nie zeigen',
        },
        'bluetoothDevices': <Object?>[
          <String, Object?>{
            'id': '4f1b2c3d-0000-4000-8000-000000000001',
            'name': 'Waage',
            'approvedAt': '2026-11-10T09:00:00Z',
          },
        ],
        'disabledFeatures': <String>['status_poll'],
      });
      final text = jsonEncode(konfigurationFuerDiagnose(config));
      for (final geheim in <String>['geheimer-hash', '987650', 'nie zeigen']) {
        expect(text, isNot(contains(geheim)), reason: geheim);
      }
      final teil = konfigurationFuerDiagnose(config);
      expect(teil['pairedTokens'], 1);
      expect(teil['disabledFeatures'], <String>['status_poll']);
      final drucker =
          (teil['printers']! as List<Object?>).single! as Map<String, Object?>;
      expect(drucker['serial'], 'X5ZT000123');
      expect(drucker['host'], '192.168.0.50');
      expect((teil['terminal']! as Map<String, Object?>)['tid'], '12345678');
      expect(teil['bluetoothDevices'], <String>['Waage']);
    });

    test('sechsstellige Zahlen werden geschwärzt, andere nicht', () {
      expect(
        schwaerze('Kopplungscode 123456 (10 Minuten gültig).'),
        'Kopplungscode ****** (10 Minuten gültig).',
      );
      expect(schwaerze('TID 12345678, Port 27182'), 'TID 12345678, Port 27182');
      expect(
        schwaerze('2026-11-10 09:00:00.123  INFO  192.168.0.50:9100'),
        '2026-11-10 09:00:00.123  INFO  192.168.0.50:9100',
      );
      expect(
        schwaerze('Transaktion 123456789012345678'),
        'Transaktion 123456789012345678',
      );
    });

    test(
      'Zeilenzahl: Vorgabe 200, höchstens 500, Unsinn ergibt die Vorgabe',
      () {
        expect(diagnoseZeilen(null), diagnoseZeilenVorgabe);
        expect(diagnoseZeilen('50'), 50);
        expect(diagnoseZeilen('9999'), diagnoseZeilenHoechstens);
        expect(diagnoseZeilen('-3'), 0);
        expect(diagnoseZeilen('viele'), diagnoseZeilenVorgabe);
      },
    );

    test('die letzten Logzeilen, auch über den Tageswechsel hinweg', () {
      final temp = Directory.systemTemp.createTempSync('connect-diag-log-');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, 'connect-2026-11-09.log')).writeAsStringSync(
        List<String>.generate(5, (i) => 'gestern $i').join('\n'),
      );
      File(p.join(temp.path, 'connect.log')).writeAsStringSync(
        '${List<String>.generate(3, (i) => 'heute $i').join('\n')}\n',
      );
      expect(letzteLogzeilen(temp, 4), <String>[
        'gestern 4',
        'heute 0',
        'heute 1',
        'heute 2',
      ]);
      expect(letzteLogzeilen(temp, 0), isEmpty);
      expect(letzteLogzeilen(Directory(p.join(temp.path, 'leer')), 5), isEmpty);
    });
  });

  group('GET /v1/diagnosis', () {
    late Directory temp;
    late Agent agent;
    late String token;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('connect-diag-');
      final store = ConfigStore.forDirectory(temp);
      agent = Agent(
        store: store,
        log: AgentLog(Directory(p.join(temp.path, 'logs'))),
        preferredPort: 0,
        openBrowser: false,
        environment: const <String, String>{},
        runProcess: FakeProcessRunner().runner,
        betriebssystem: 'linux',
      );
      // Ohne Token erzeugt der Start einen Kopplungscode und loggt ihn.
      await agent.start();
      token = await agent.context.pairing.issueToken();
    });

    tearDown(() async {
      await agent.stop();
      temp.deleteSync(recursive: true);
    });

    test('ohne Token 401', () async {
      final antwort = await anAgent(agent.port, 'GET', '/v1/diagnosis');
      expect(antwort.status, 401);
    });

    test('nennt Version, Kennung, Konfiguration, Zustände, Log – ohne '
        'Token-Hash und Kopplungscode', () async {
      final config = await agent.context.store.load();
      final hash = config.tokenHashes.single;
      final logText = File(
        p.join(temp.path, 'logs', 'connect.log'),
      ).readAsStringSync();
      final code = RegExp(
        r'Kopplungscode (\d{6})',
      ).firstMatch(logText)!.group(1)!;

      final antwort = await anAgent(
        agent.port,
        'GET',
        '/v1/diagnosis?lines=50',
        token: token,
      );
      expect(antwort.ok, isTrue, reason: antwort.text);
      final d = antwort.json;
      expect(d['version'], agentVersion);
      expect(d['installationId'], config.installationId);
      expect(d['features'], contains('diagnosis'));
      expect(
        d.keys,
        containsAll(<String>[
          'os',
          'uptimeSeconds',
          'port',
          'config',
          'printers',
          'lastErrors',
          'log',
          'relocations',
          'update',
        ]),
      );
      final zeilen = (d['log']! as List<Object?>).cast<String>();
      expect(zeilen.length, lessThanOrEqualTo(50));
      expect(zeilen.any((z) => z.contains('Kopplungscode ******')), isTrue);
      expect(antwort.text, isNot(contains(hash)));
      expect(antwort.text, isNot(contains(code)));
      expect(antwort.text, isNot(contains('BEGIN')), reason: 'kein Schlüssel');
    });
  });

  group('doctor', () {
    test('nennt abgeschaltete Neuerungen', () async {
      final temp = Directory.systemTemp.createTempSync('connect-doctor-neu-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final paths = ConfigPaths(temp);
      Future<String> bericht() async => formatDoctorReport(
        await collectDoctorReport(
          paths: paths,
          probe: (_) async => null,
          printerStates: () async => const <Map<String, Object?>>[],
          runProcess: FakeProcessRunner().runner,
        ),
      );
      expect(await bericht(), contains('Neuerungen     alle an'));
      await ConfigStore(paths).mutate(
        (c) =>
            c.copyWith(disabledFeatures: <String>['status_poll', 'sleep_lock']),
      );
      expect(
        await bericht(),
        contains('abgeschaltet: status_poll, sleep_lock'),
      );
    });
  });
}
