import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/fake_hps.dart';
import 'support/fake_process_runner.dart';

const String _tid = '12345678';

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late DateTime jetzt;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-tw-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    jetzt = DateTime(2026, 11, 10, 9);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('Wachhalter', () {
    test('merkt TID und Bestätigung, schreibt eine Bestätigung höchstens '
        'alle 15 min', () async {
      final w = TerminalWarmhalter(
        store: store,
        log: log,
        intervall: const Duration(hours: 1),
        clock: () => jetzt,
        macLesen: (_) async => '0:26:ab:0:0:2',
      );
      addTearDown(w.stop);
      w.merken('192.168.0.60', 8080, tid: _tid, bestaetigt: true);
      await warteBis(
        () async => (await store.load()).terminal?.confirmedAt != null,
      );
      final erste = (await store.load()).terminal!;
      expect(erste.tid, _tid);
      expect(erste.mac, '00:26:ab:00:00:02');
      expect(erste.confirmedAt, jetzt.toUtc());

      jetzt = jetzt.add(const Duration(minutes: 5));
      w.merken('192.168.0.60', 8080, tid: _tid, bestaetigt: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await store.load()).terminal!.confirmedAt, erste.confirmedAt);

      jetzt = jetzt.add(bestaetigungAuffrischen);
      w.merken('192.168.0.60', 8080, tid: _tid, bestaetigt: true);
      await warteBis(
        () async =>
            (await store.load()).terminal!.confirmedAt != erste.confirmedAt,
      );
    });

    test(
      'unbestätigte neue Adresse: ohne TID und Bestätigung (wie 1.4.2)',
      () async {
        await store.mutate(
          (c) => c.copyWith(
            terminal: TerminalConfig(
              host: '192.168.0.60',
              tid: _tid,
              confirmedAt: jetzt.toUtc(),
            ),
          ),
        );
        final w = TerminalWarmhalter(
          store: store,
          log: log,
          intervall: const Duration(hours: 1),
        );
        addTearDown(w.stop);
        w.merken('192.168.0.61', 8080);
        await warteBis(
          () async => (await store.load()).terminal!.host == '192.168.0.61',
        );
        final t = (await store.load()).terminal!;
        expect(t.tid, isNull);
        expect(t.confirmedAt, isNull);
      },
    );

    test('dreimal nicht erreichbar: einmal Suche anstoßen; während einer '
        'Zahlung keine Berührung', () async {
      var erreichbar = false;
      var beruehrt = 0;
      var suchen = 0;
      final belegung = TerminalBelegung();
      final w = TerminalWarmhalter(
        store: store,
        log: log,
        intervall: const Duration(milliseconds: 15),
        belegung: belegung,
        probe: (host, port, timeout) async {
          beruehrt++;
          return erreichbar;
        },
      )..beiDauerndUnerreichbar = () => suchen++;
      addTearDown(w.stop);
      w.startAus(
        AgentConfig(
          terminal: TerminalConfig(host: '192.168.0.60', tid: _tid),
        ),
      );
      await warteBis(() async => beruehrt >= 6, grund: 'sechs Berührungen');
      expect(suchen, 1);
      expect(w.erreichbar, isFalse);
      expect(w.geprueftAm, isNotNull);

      final beleg = belegung.belegen(
        tid: _tid,
        host: '192.168.0.60',
        port: 8080,
        art: LangerAufruf.zahlung,
      )!;
      final vorher = beruehrt;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(beruehrt, vorher, reason: 'die Zahlung hält es wach');
      belegung.freigeben(beleg);
      erreichbar = true;
      await warteBis(() async => w.erreichbar ?? false);

      final feld = w.statusFeld(
        TerminalConfig(host: '192.168.0.60', tid: _tid),
      )!;
      expect(feld['tid'], _tid);
      expect(feld['reachable'], isTrue);
      expect(feld['checkedAt'], isNotNull);
      expect(w.statusFeld(null), isNull);
    });
  });

  group('Wiederfinder', () {
    late FakeHpsServer richtig;
    late FakeHpsServer fremd;
    late TerminalBelegung belegung;
    late List<DiscoveredTerminal> funde;
    late int sucheAufrufe;
    late EventBus events;
    late TerminalWiederfinder finder;

    setUp(() async {
      richtig = await FakeHpsServer.starten();
      fremd = await FakeHpsServer.starten(tid: '87654321');
      belegung = TerminalBelegung();
      events = EventBus();
      sucheAufrufe = 0;
      funde = <DiscoveredTerminal>[
        DiscoveredTerminal(host: '127.0.0.1', port: fremd.port, tids: const []),
        DiscoveredTerminal(
          host: '127.0.0.1',
          port: richtig.port,
          tids: const [],
        ),
      ];
      await store.mutate(
        (c) => c.copyWith(
          terminal: TerminalConfig(host: '192.168.0.60', tid: _tid),
        ),
      );
      finder = TerminalWiederfinder(
        store: store,
        bridge: HpsBridge(log: log),
        belegung: belegung,
        events: events,
        log: log,
        clock: () => jetzt,
        suche: () async {
          sucheAufrufe++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return TerminalDiscoveryResult(found: funde, scanned: const []);
        },
      );
    });

    tearDown(() async {
      await richtig.stop();
      await fremd.stop();
      await events.close();
    });

    test(
      'genau ein bestätigter Treffer: übernommen, still, mit Eintrag',
      () async {
        final gesehen = <AgentEvent>[];
        final abo = events.stream.listen(gesehen.add);
        addTearDown(abo.cancel);
        final fund = await finder.suche(_tid);
        expect(fund?.port, richtig.port);
        expect(fund?.umgezogen, isTrue);
        final config = await store.load();
        expect(config.terminal?.port, richtig.port);
        expect(config.terminal?.confirmedAt, jetzt.toUtc());
        expect(config.relocations.single.art, GeraeteArt.terminal);
        expect(config.relocations.single.kennung, _tid);
        await Future<void>.delayed(Duration.zero);
        expect(gesehen.single.type, eventTerminalRelocated);
        // Die Treffer werden der Reihe nach gefragt, nie gleichzeitig.
        expect(fremd.an('/api/terminals/$_tid/diagnosis'), hasLength(1));
      },
    );

    test('zwei bestätigen dieselbe TID: keiner übernommen', () async {
      fremd.tid = _tid;
      expect(await finder.suche(_tid), isNull);
      expect((await store.load()).terminal?.host, '192.168.0.60');
    });

    test('während eines langen Aufrufs: keine Suche', () async {
      belegung.belegen(
        tid: '99999999',
        host: '192.168.0.70',
        port: 8080,
        art: LangerAufruf.zahlung,
      );
      expect(await finder.suche(_tid), isNull);
      expect(sucheAufrufe, 0);
    });

    test('gleichzeitige Anstöße: genau eine Suche', () async {
      final ergebnisse = await Future.wait(<Future<TerminalFund?>>[
        finder.suche(_tid),
        finder.suche('012345678'),
        finder.suche(_tid),
      ]);
      expect(ergebnisse.map((f) => f?.port).toSet(), <int?>{richtig.port});
      expect(sucheAufrufe, 1);
      expect(finder.suchen, 1);
    });

    test('terminal_relocate aus: keine Suche', () async {
      await store.mutate(
        (c) => c.copyWith(disabledFeatures: <String>['terminal_relocate']),
      );
      expect(await finder.suche(_tid), isNull);
      expect(sucheAufrufe, 0);
    });

    test('im Hintergrund höchstens alle fünf Minuten', () async {
      finder.imHintergrund();
      await warteBis(() async => finder.suchen == 1);
      await warteBis(() async => (await store.load()).relocations.isNotEmpty);
      finder.imHintergrund();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(finder.suchen, 1);
      jetzt = jetzt.add(terminalSucheAbstand);
      finder.imHintergrund();
      await warteBis(() async => finder.suchen == 2);
    });

    test('Route locate und das Statusfeld terminal', () async {
      final ctx = AgentContext(
        store: store,
        log: log,
        startedAt: DateTime.now(),
        environment: const <String, String>{},
        pairing: Pairing(
          store: store,
          log: log,
          runProcess: FakeProcessRunner().runner,
        ),
      );
      final w = TerminalWarmhalter(
        store: store,
        log: log,
        intervall: const Duration(hours: 1),
      );
      addTearDown(w.stop);
      ctx.terminalZustand = w.statusFeld;
      final server = await shelf_io.serve(
        buildHandler(
          ctx,
          extraRoutes: <RouteRegistrar>[
            terminalRoutes(belegung: belegung, wiederfinder: finder),
          ],
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      ctx.port = server.port;
      final token = await ctx.pairing.issueToken();

      final ohneTid = await anAgent(
        server.port,
        'POST',
        '/v1/terminal/locate',
        token: token,
        rumpf: const <String, Object?>{},
      );
      expect(ohneTid.code, errorBadRequest);

      final antwort = await anAgent(
        server.port,
        'POST',
        '/v1/terminal/locate',
        token: token,
        rumpf: const <String, Object?>{'tid': _tid},
      );
      expect(antwort.ok, isTrue, reason: antwort.text);
      expect(antwort.json['port'], richtig.port);
      expect(antwort.json['relocated'], isTrue);
      expect(antwort.json['from'], '192.168.0.60:8080');

      final keiner = await anAgent(
        server.port,
        'POST',
        '/v1/terminal/locate',
        token: token,
        rumpf: const <String, Object?>{'tid': '55555555'},
      );
      expect(keiner.code, errorDeviceNotFound);

      final status = await anAgent(
        server.port,
        'GET',
        '/v1/status',
        token: token,
      );
      final terminal = status.json['terminal']! as Map<String, Object?>;
      expect(terminal['tid'], _tid);
      expect(terminal['port'], richtig.port);
      expect(terminal['confirmedAt'], isNotNull);
      final ohneToken = await anAgent(server.port, 'GET', '/v1/status');
      expect(ohneToken.json.containsKey('terminal'), isFalse);
    });
  });
}
