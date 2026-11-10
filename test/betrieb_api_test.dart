import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:kasseneck_connect/src/update/feed.dart';
import 'package:kasseneck_connect/src/update/updater.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/fake_hps.dart';
import 'support/fake_process_runner.dart';

String _fixture(String name) =>
    File('test/fixtures/update/$name').readAsStringSync();

void main() {
  group('Updater', () {
    late Directory cache;
    late EventBus bus;
    late List<AgentEvent> ereignisse;
    late FakeProcessRunner run;
    final paket = utf8.encode('xar! Testpaket 1.4.1');

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('connect-upd-sperre-');
      bus = EventBus();
      ereignisse = <AgentEvent>[];
      final abo = bus.stream.listen(ereignisse.add);
      addTearDown(() async {
        await abo.cancel();
        await bus.close();
        await cache.delete(recursive: true);
      });
      run = FakeProcessRunner()
        ..antwort = (executable, arguments) async => switch (executable) {
          'pkgutil' => ProcessResult(
            1,
            0,
            _fixture('pkgutil-check-signature-1.3.0.txt'),
            '',
          ),
          'spctl' => ProcessResult(
            2,
            0,
            '',
            _fixture('spctl-install-1.3.0.txt'),
          ),
          _ => null,
        };
    });

    ConnectUpdater updater({
      required Future<bool> Function() beschaeftigt,
      Future<bool> Function(Duration)? warteBisFrei,
      Downloader? download,
    }) => ConnectUpdater(
      feed: UpdateFeed(
        fetch: (uri, timeout) async => jsonEncode(<String, Object?>{
          'version': '1.4.1',
          'files': <String, Object?>{
            'darwin-arm64': <String, Object?>{
              'url':
                  'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.1/KasseneckConnect-macos-arm64.pkg',
              'sha256': sha256.convert(paket).toString(),
              'size': paket.length,
            },
          },
        }),
      ),
      download:
          download ??
          (url, target, onProgress) async => target.writeAsBytes(paket),
      run: run.runner,
      events: bus,
      cacheDir: cache,
      platformKey: 'darwin-arm64',
      current: '1.4.0',
      operatingSystem: 'macos',
      beschaeftigt: beschaeftigt,
      warteBisFrei: warteBisFrei,
    );

    test(
      'während eines Vorgangs: update_device_busy, nichts geladen',
      () async {
        final u = updater(beschaeftigt: () async => true);
        await expectLater(
          u.start(),
          throwsA(
            isA<UpdateFailure>().having(
              (f) => f.code,
              'code',
              errorUpdateDeviceBusy,
            ),
          ),
        );
        expect(run.calls, isEmpty);
        expect(u.busy, isFalse);
      },
    );

    test('beginnt ein Vorgang während des Ladens: Phase waiting, der '
        'Installer öffnet erst danach', () async {
      var laeuft = false;
      final frei = Completer<bool>();
      final u = updater(
        beschaeftigt: () async => laeuft,
        warteBisFrei: (_) => frei.future,
        download: (url, target, onProgress) async {
          laeuft = true; // eine Zahlung beginnt mitten im Laden
          await target.writeAsBytes(paket);
        },
      );
      await u.start();
      await warteBis(
        () async => ereignisse.any((e) => e.data['phase'] == 'waiting'),
        grund: 'Phase waiting',
      );
      expect(run.sawCall('open', <String>[]), isFalse);
      expect(run.lines.where((l) => l.startsWith('open ')), isEmpty);
      laeuft = false;
      frei.complete(true);
      await u.running;
      final phasen = ereignisse
          .where((e) => e.type == eventUpdateProgress)
          .map((e) => e.data['phase'])
          .toList();
      expect(phasen.indexOf('waiting'), lessThan(phasen.indexOf('ready')));
      expect(run.lines.where((l) => l.startsWith('open ')), hasLength(1));
    });
  });

  group('über den Agenten (zwei Kassen)', () {
    late Directory temp;
    late ConfigStore store;
    late FakeHpsServer hps;
    late Agent agent;
    late String kasseA;
    late String kasseB;
    var neustarts = 0;
    DateTime? neustartAm;

    Future<void> starten({bool mitNeustart = true}) async {
      agent = Agent(
        store: store,
        log: AgentLog(Directory(p.join(temp.path, 'logs'))),
        preferredPort: 0,
        openBrowser: false,
        environment: const <String, String>{},
        betriebssystem: 'linux',
        runProcess: FakeProcessRunner().runner,
        neustart: mitNeustart
            ? () async {
                neustarts++;
                neustartAm = DateTime.now();
              }
            : null,
      );
      await agent.start();
      kasseA = await agent.context.pairing.issueToken();
      kasseB = await agent.context.pairing.issueToken();
    }

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('connect-betrieb-api-');
      store = ConfigStore.forDirectory(temp);
      hps = await FakeHpsServer.starten();
      neustarts = 0;
      neustartAm = null;
    });

    tearDown(() async {
      await agent.stop();
      await hps.stop();
      temp.deleteSync(recursive: true);
    });

    Future<AgentAntwort> zahleAusA() => anAgent(
      agent.port,
      'POST',
      '/v1/terminal/payment',
      token: kasseA,
      rumpf: <String, Object?>{
        'host': '127.0.0.1',
        'port': hps.port,
        'tid': '12345678',
        'amountCents': 100,
        'transactionId': '1',
      },
    );

    Future<void> wartetAmTerminal() => warteBis(
      () async => hps.an('/api/transaction/payment').isNotEmpty,
      grund: 'Zahlung am Terminal',
    );

    test('features: die Fähigkeiten ab 1.5.0, abschaltbar', () async {
      await starten();
      final status = await anAgent(agent.port, 'GET', '/v1/status');
      expect(
        status.json['features'],
        containsAll(<String>[
          'identity',
          'printer_status',
          'relocate',
          'busy_lock',
          'restart',
        ]),
      );
      await store.mutate(
        (c) => c.copyWith(
          disabledFeatures: <String>['printer_status', 'printer_relocate'],
        ),
      );
      final danach =
          (await anAgent(agent.port, 'GET', '/v1/status')).json['features']!
              as List<Object?>;
      expect(danach, isNot(contains('printer_status')));
      expect(danach, contains('relocate'), reason: 'Terminal noch an');
      await store.mutate(
        (c) => c.copyWith(
          disabledFeatures: <String>['printer_relocate', 'terminal_relocate'],
        ),
      );
      expect(
        (await anAgent(agent.port, 'GET', '/v1/status')).json['features'],
        isNot(contains('relocate')),
      );
    });

    test(
      'ohne Autostart-Neustart: kein restart in features, Pfad 404',
      () async {
        await starten(mitNeustart: false);
        final status = await anAgent(agent.port, 'GET', '/v1/status');
        expect(status.json['features'], isNot(contains('restart')));
        final antwort = await anAgent(
          agent.port,
          'POST',
          '/v1/restart',
          token: kasseA,
        );
        expect(antwort.status, 404);
      },
    );

    test('Kasse A zahlt, Kasse B will neu starten: restart_busy; Status '
        'antwortet sofort', () async {
      await starten();
      hps.verzoegerung['/api/transaction/payment'] = const Duration(
        milliseconds: 800,
      );
      final zahlung = zahleAusA();
      await wartetAmTerminal();
      expect(agent.context.vorgaenge!.laufen, isTrue);

      final uhr = Stopwatch()..start();
      final status = await anAgent(
        agent.port,
        'GET',
        '/v1/status',
        token: kasseB,
      );
      expect(uhr.elapsed, lessThan(const Duration(milliseconds: 300)));
      expect(status.ok, isTrue);

      final neu = await anAgent(
        agent.port,
        'POST',
        '/v1/restart',
        token: kasseB,
      );
      expect(neu.status, 409);
      expect(neu.code, errorRestartBusy);
      expect((await zahlung).ok, isTrue);
      expect(agent.context.vorgaenge!.laufen, isFalse);
      expect(neustarts, 0);
    });

    test(
      'Neustart ohne Vorgang: Antwort, dann nach einer halben Sekunde',
      () async {
        await starten();
        final uhr = Stopwatch()..start();
        final antwort = await anAgent(
          agent.port,
          'POST',
          '/v1/restart',
          token: kasseA,
        );
        expect(antwort.json, <String, Object?>{'ok': true, 'restarting': true});
        await warteBis(() async => neustarts == 1, grund: 'Neustart');
        expect(uhr.elapsed, greaterThanOrEqualTo(neustartVerzug));
      },
    );

    test('beginnt nach der Antwort noch eine Zahlung, wartet der Neustart sie '
        'ab', () async {
      await starten();
      hps.verzoegerung['/api/transaction/payment'] = const Duration(
        milliseconds: 900,
      );
      final antwort = await anAgent(
        agent.port,
        'POST',
        '/v1/restart',
        token: kasseA,
      );
      expect(antwort.ok, isTrue);
      final zahlung = zahleAusA();
      await wartetAmTerminal();
      final ende = await zahlung;
      final zahlungFertig = DateTime.now();
      expect(ende.ok, isTrue);
      await warteBis(() async => neustarts == 1, grund: 'Neustart');
      expect(
        neustartAm!.isBefore(
          zahlungFertig.subtract(const Duration(milliseconds: 50)),
        ),
        isFalse,
        reason: 'nicht vor dem Ende der Zahlung',
      );
    });

    test(
      'busy_lock aus: Neustart auch während einer Zahlung (keine Sperre)',
      () async {
        await starten();
        await store.mutate(
          (c) => c.copyWith(disabledFeatures: <String>['busy_lock']),
        );
        hps.verzoegerung['/api/transaction/payment'] = const Duration(
          milliseconds: 600,
        );
        final zahlung = zahleAusA();
        await wartetAmTerminal();
        final neu = await anAgent(
          agent.port,
          'POST',
          '/v1/restart',
          token: kasseB,
        );
        expect(neu.ok, isTrue);
        await zahlung;
      },
    );
  });
}
