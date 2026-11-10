import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:kasseneck_connect/src/update/feed.dart';
import 'package:kasseneck_connect/src/update/updater.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/fake_epos.dart';
import 'support/fake_hps.dart';
import 'support/fake_process_runner.dart';

String _fixture(String name) =>
    File('test/fixtures/update/$name').readAsStringSync();

/// Autostart, der nur meldet, ob er eingerichtet ist.
class _Autostart implements Autostart {
  _Autostart({required this.eingerichtet});

  final bool eingerichtet;

  @override
  String get target => '/pfad/zum/eintrag';

  @override
  Future<bool> isInstalled() async => eingerichtet;

  @override
  Future<AutostartResult> install() => throw UnimplementedError();

  @override
  Future<AutostartResult> uninstall() => throw UnimplementedError();
}

void main() {
  group('neustartPlanen', () {
    test('nach einer halben Sekunde; ein Vorgang, der dazwischen beginnt, '
        'wird abgewartet', () {
      fakeAsync((async) {
        final vorgaenge = LaufendeVorgaenge(
          clock: () => DateTime(2026, 11, 10, 9).add(async.elapsed),
        );
        Duration? neustartNach;
        neustartPlanen(
          vorgaenge: vorgaenge,
          neustart: () async => neustartNach = async.elapsed,
        );
        async.elapse(const Duration(milliseconds: 100));
        final zahlung = vorgaenge.beginne(VorgangsArt.terminal);
        async.elapse(const Duration(seconds: 2));
        expect(neustartNach, isNull, reason: 'die Zahlung läuft');
        vorgaenge.beende(zahlung);
        async.flushMicrotasks();
        expect(neustartNach, const Duration(milliseconds: 2100));
        vorgaenge.stop();
      });
    });

    test('ohne Vorgänge genau nach der Verzögerung', () {
      fakeAsync((async) {
        Duration? neustartNach;
        neustartPlanen(neustart: () async => neustartNach = async.elapsed);
        async.elapse(neustartVerzug - const Duration(milliseconds: 1));
        expect(neustartNach, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(neustartNach, neustartVerzug);
      });
    });
  });

  group('neustartMoeglich', () {
    test('nur, wenn launchd bzw. systemd Connect gestartet hat', () async {
      final eingerichtet = _Autostart(eingerichtet: true);
      // Von launchd gestartet (Label des LaunchAgents).
      expect(
        await neustartMoeglich('macos', eingerichtet, <String, String>{
          'XPC_SERVICE_NAME': autostartLabel,
        }),
        isTrue,
      );
      // Von Hand im Terminal: Terminal.app setzt XPC_SERVICE_NAME=0.
      expect(
        await neustartMoeglich('macos', eingerichtet, <String, String>{
          'XPC_SERVICE_NAME': '0',
        }),
        isFalse,
      );
      expect(
        await neustartMoeglich('macos', eingerichtet, const <String, String>{}),
        isFalse,
      );
      expect(
        await neustartMoeglich('linux', eingerichtet, <String, String>{
          'INVOCATION_ID': '0123456789abcdef0123456789abcdef',
        }),
        isTrue,
      );
      expect(
        await neustartMoeglich('linux', eingerichtet, const <String, String>{}),
        isFalse,
      );
      // Autostart nicht eingerichtet oder Windows: nie.
      expect(
        await neustartMoeglich(
          'macos',
          _Autostart(eingerichtet: false),
          <String, String>{'XPC_SERVICE_NAME': autostartLabel},
        ),
        isFalse,
      );
      expect(
        await neustartMoeglich('windows', eingerichtet, <String, String>{
          'XPC_SERVICE_NAME': autostartLabel,
          'INVOCATION_ID': 'x',
        }),
        isFalse,
      );
    });
  });

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

    Future<void> starten({bool mitNeustart = true}) async {
      agent = Agent(
        store: store,
        log: AgentLog(Directory(p.join(temp.path, 'logs'))),
        preferredPort: 0,
        openBrowser: false,
        environment: const <String, String>{},
        betriebssystem: 'linux',
        runProcess: FakeProcessRunner().runner,
        neustart: mitNeustart ? () async => neustarts++ : null,
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
        'antwortet, während die Zahlung noch läuft', () async {
      await starten();
      hps.verzoegerung['/api/transaction/payment'] = const Duration(seconds: 2);
      var zahlungFertig = false;
      final zahlung = zahleAusA().whenComplete(() => zahlungFertig = true);
      await wartetAmTerminal();
      expect(agent.context.vorgaenge!.laufen, isTrue);

      final status = await anAgent(
        agent.port,
        'GET',
        '/v1/status',
        token: kasseB,
      );
      expect(status.ok, isTrue);
      expect(zahlungFertig, isFalse, reason: 'Status wartet nie auf Zahlung');

      final neu = await anAgent(
        agent.port,
        'POST',
        '/v1/restart',
        token: kasseB,
      );
      expect(neu.status, 409);
      expect(neu.code, errorRestartBusy);
      expect(zahlungFertig, isFalse);
      expect((await zahlung).ok, isTrue);
      expect(agent.context.vorgaenge!.laufen, isFalse);
      expect(neustarts, 0);
    });

    test('Status antwortet, während ein Bon an einem hängenden Drucker '
        'steht', () async {
      await starten();
      // ePOS-Drucker, der erst nach einer Minute antwortet: der Bon steht.
      final epos = await FakeEposServer.start(
        mode: FakeEposMode.slow,
        delay: const Duration(minutes: 1),
      );
      addTearDown(epos.stop);
      final drucker = await agent.printers.upsert(
        PrinterConfig(
          id: '',
          name: 'Bon',
          kind: PrinterKind.epos,
          host: '127.0.0.1',
          port: epos.port,
        ),
      );
      var bonFertig = false;
      final bon = anAgent(
        agent.port,
        'POST',
        '/v1/print',
        token: kasseA,
        rumpf: <String, Object?>{
          'printerId': drucker.id,
          'jobId': 'beleg-1',
          'bytes': base64Encode(<int>[0x1B, 0x40, 0x41, 0x0A]),
        },
      ).whenComplete(() => bonFertig = true);
      await warteBis(
        () async => epos.bodies.any((b) => b.contains('<command>')),
        grund: 'Bon am Drucker',
      );
      final status = await anAgent(
        agent.port,
        'GET',
        '/v1/status',
        token: kasseB,
      );
      expect(status.ok, isTrue);
      expect(bonFertig, isFalse, reason: 'Status wartet nie auf den Bon');
      // Der Bon endet mit dem Agenten im tearDown.
      unawaited(bon.then<void>((_) {}, onError: (Object _) {}));
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

    test(
      'busy_lock aus: der Neustart wartet trotzdem auf die laufende Zahlung',
      () async {
        // Der Not-Aus gilt der Belegung des Terminals und der Update-Sperre;
        // ein Neustart risse die Zahlung dagegen sicher ab.
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
        expect(neu.status, 409);
        expect(neu.code, errorRestartBusy);
        expect((await zahlung).ok, isTrue);
        expect(neustarts, 0);
      },
    );
  });
}
