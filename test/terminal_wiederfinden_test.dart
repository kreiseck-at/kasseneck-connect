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

    test('H10: ein früherer Speichervorgang, der noch die MAC liest, '
        'überschreibt keinen späteren', () async {
      final mac = Completer<String?>();
      final w = TerminalWarmhalter(
        store: store,
        log: log,
        intervall: const Duration(hours: 1),
        clock: () => jetzt,
        macLesen: (_) => mac.future,
      );
      addTearDown(w.stop);
      w.merken('192.168.0.60', 8080, tid: _tid, bestaetigt: true);
      jetzt = jetzt.add(const Duration(seconds: 1));
      // Danach testet die Kasse ein Terminal unter einer anderen Adresse.
      w.merken('192.168.0.61', 8080);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      mac.complete('00:26:ab:00:00:02');
      await w.erledigt;
      // Auch ein Speichervorgang, der nicht in der Reihe stünde, wäre jetzt
      // durch.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final t = (await store.load()).terminal!;
      expect(t.host, '192.168.0.61', reason: 'der spätere Aufruf zählt');
      expect(t.tid, isNull);
    });

    test('H10: ein Speichervorgang überschreibt keine andere Adresse, die '
        'nach seinem Aufruf bestätigt wurde (etwa von der Suche)', () async {
      final mac = Completer<String?>();
      final w = TerminalWarmhalter(
        store: store,
        log: log,
        intervall: const Duration(hours: 1),
        clock: () => jetzt,
        macLesen: (_) => mac.future,
      );
      addTearDown(w.stop);
      w.merken('192.168.0.60', 8080, tid: _tid, bestaetigt: true);
      jetzt = jetzt.add(const Duration(seconds: 1));
      w.merken('192.168.0.62', 8080);
      // Inzwischen bestätigt die Suche das Terminal unter .63.
      jetzt = jetzt.add(const Duration(seconds: 1));
      await store.mutate(
        (c) => c.copyWith(
          terminal: TerminalConfig(
            host: '192.168.0.63',
            tid: _tid,
            confirmedAt: jetzt.toUtc(),
          ),
        ),
      );
      mac.complete(null);
      await w.erledigt;
      final t = (await store.load()).terminal!;
      expect(t.host, '192.168.0.63');
      expect(t.tid, _tid);
      expect(t.confirmedAt, jetzt.toUtc());
    });

    test('dreimal nicht erreichbar: Suche anstoßen (danach bei jeder weiteren '
        'Fehlberührung, gedrosselt von der Suche); während einer Zahlung '
        'keine Berührung', () async {
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
      // Ab der dritten Fehlberührung jede: die erste nach drei, dann weiter.
      expect(suchen, greaterThanOrEqualTo(2));
      expect(suchen, lessThanOrEqualTo(beruehrt - 2));
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
      // Eine Suche, die noch läuft, fragt sonst die Ports des nächsten Tests.
      await finder.beenden();
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
        final fund = await finder.suche('0$_tid');
        expect(fund?.port, richtig.port);
        expect(fund?.umgezogen, isTrue);
        final config = await store.load();
        expect(config.terminal?.port, richtig.port);
        expect(config.terminal?.confirmedAt, jetzt.toUtc());
        expect(config.terminal?.serial, 'P000000K00001', reason: 'sn');
        expect(config.relocations.single.art, GeraeteArt.terminal);
        expect(config.relocations.single.kennung, _tid);
        await Future<void>.delayed(Duration.zero);
        expect(gesehen.single.type, eventTerminalRelocated);
        // Die Treffer werden der Reihe nach gefragt, nie gleichzeitig.
        expect(fremd.an('/api/terminals/$_tid/diagnosis'), hasLength(1));
      },
    );

    test('H10: während der Suche richtet die Kasse ein anderes Terminal ein '
        '– der Fund wird nicht übernommen', () async {
      final weiter = Completer<void>();
      final langsam = TerminalWiederfinder(
        store: store,
        bridge: HpsBridge(log: log),
        belegung: belegung,
        events: events,
        log: log,
        clock: () => jetzt,
        suche: () async {
          await weiter.future;
          return TerminalDiscoveryResult(found: funde, scanned: const []);
        },
      );
      addTearDown(langsam.beenden);
      final suche = langsam.suche(_tid);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await store.mutate(
        (c) => c.copyWith(
          terminal: TerminalConfig(
            host: '192.168.0.70',
            tid: '87654321',
            confirmedAt: jetzt.toUtc(),
          ),
        ),
      );
      weiter.complete();
      expect(await suche, isNull);
      final t = (await store.load()).terminal!;
      expect(t.host, '192.168.0.70');
      expect(t.tid, '87654321');
      expect((await store.load()).relocations, isEmpty);
    });

    test('locate für eine andere TID als die gemerkte (vor der Suche schon '
        'so): übernommen wie bisher', () async {
      await store.mutate(
        (c) => c.copyWith(
          terminal: TerminalConfig(host: '192.168.0.70', tid: '99999999'),
        ),
      );
      final fund = await finder.suche(_tid);
      expect(fund?.port, richtig.port);
      expect((await store.load()).terminal?.tid, _tid);
    });

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
      addTearDown(() {
        if (log.file.existsSync()) printOnFailure(log.file.readAsStringSync());
      });
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

    test('über Nacht aus, morgens unter neuer Adresse: nur bei offener Kasse, '
        'Abstand 5 → 15 → 60 min, nach dem Fund wieder 5', () async {
      // Ohne Takt: jede Berührung von Hand, die Uhr wird gestellt – kein
      // Warten auf echte Zeit.
      funde = <DiscoveredTerminal>[]; // nachts: kein Terminal im Netz
      var amNeuenOrt = false;
      DateTime? kasse;
      final w = TerminalWarmhalter(
        store: store,
        log: log,
        intervall: const Duration(days: 1),
        belegung: belegung,
        clock: () => jetzt,
        probe: (host, port, timeout) async =>
            amNeuenOrt && port == richtig.port,
      );
      // Wie im Agenten: der Wiederfinder meldet dem Wachhalter die neue
      // Adresse.
      final finder = TerminalWiederfinder(
        store: store,
        bridge: HpsBridge(log: log),
        belegung: belegung,
        warmhalter: w,
        log: log,
        clock: () => jetzt,
        kasseZuletzt: () => kasse,
        suche: () async {
          sucheAufrufe++;
          return TerminalDiscoveryResult(found: funde, scanned: const []);
        },
      );
      addTearDown(() async {
        w.stop();
        await finder.beenden();
        await w.erledigt;
      });
      w
        ..beiDauerndUnerreichbar = finder.imHintergrund
        ..beiWiederErreichbar = finder.wiederErreichbar
        ..startAus(await store.load());

      Future<void> beruehre({
        Duration nach = const Duration(minutes: 1),
      }) async {
        jetzt = jetzt.add(nach);
        await w.beruehren();
        await finder.erledigt();
      }

      // Nachts ist keine Kasse offen: keine Suche, so oft es auch ausfällt.
      for (var i = 0; i < 20; i++) {
        await beruehre();
      }
      expect(finder.suchen, 0);

      // Die Kasse öffnet: erste Suche, ohne Fund.
      kasse = jetzt;
      await beruehre(nach: Duration.zero);
      expect(finder.suchen, 1);
      // Innerhalb von 5 min keine zweite.
      kasse = jetzt.add(const Duration(minutes: 4));
      await beruehre(nach: const Duration(minutes: 4));
      expect(finder.suchen, 1);
      // Nach 5 min die zweite – wieder nichts, der Abstand wächst auf 15.
      kasse = jetzt.add(const Duration(minutes: 1));
      await beruehre();
      expect(finder.suchen, 2);
      kasse = jetzt.add(const Duration(minutes: 14));
      await beruehre(nach: const Duration(minutes: 14));
      expect(finder.suchen, 2, reason: 'erst nach 15 min');
      kasse = jetzt.add(const Duration(minutes: 1));
      await beruehre();
      expect(finder.suchen, 3);
      // Jetzt 60 min.
      kasse = jetzt.add(const Duration(minutes: 59));
      await beruehre(nach: const Duration(minutes: 59));
      expect(finder.suchen, 3);

      // Morgens: das Terminal ist unter neuer Adresse zurück.
      funde = <DiscoveredTerminal>[
        DiscoveredTerminal(
          host: '127.0.0.1',
          port: richtig.port,
          tids: const [],
        ),
      ];
      amNeuenOrt = true;
      kasse = jetzt.add(const Duration(minutes: 1));
      await beruehre();
      expect(finder.suchen, 4);
      expect((await store.load()).terminal?.port, richtig.port);
      await beruehre();
      expect(w.erreichbar, isTrue);
      expect(terminalSucheAbstaende, const <Duration>[
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(minutes: 60),
      ]);
    });

    test('die Sperrzeit gilt nur nach einer echten Suche', () async {
      final beleg = belegung.belegen(
        tid: '99999999',
        host: '192.168.0.70',
        port: 8080,
        art: LangerAufruf.zahlung,
      )!;
      finder.imHintergrund();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(finder.suchen, 0, reason: 'belegt: keine Suche');
      belegung.freigeben(beleg);
      finder.imHintergrund();
      await warteBis(() async => finder.suchen == 1, grund: 'gleich danach');
    });

    test('die Diagnose der Suche ist ein kurzer Aufruf: eine Zahlung wartet '
        'sie ab, nie zwei Aufrufe zugleich am Terminal', () async {
      funde = <DiscoveredTerminal>[
        DiscoveredTerminal(
          host: '127.0.0.1',
          port: richtig.port,
          tids: const [],
        ),
      ];
      richtig.verzoegerung['/api/terminals/'] = const Duration(
        milliseconds: 300,
      );
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

      final suche = finder.suche(_tid);
      await warteBis(
        () async => richtig.an('/api/terminals/').isNotEmpty,
        grund: 'Diagnose der Suche unterwegs',
      );
      final zahlung = await anAgent(
        server.port,
        'POST',
        '/v1/terminal/payment',
        token: token,
        rumpf: <String, Object?>{
          'host': '127.0.0.1',
          'port': richtig.port,
          'tid': _tid,
          'amountCents': 100,
          'transactionId': '1',
        },
      );
      await suche;
      expect(zahlung.ok, isTrue, reason: zahlung.text);
      final diagnose = richtig.an('/api/terminals/').single;
      final geld = richtig.an('/api/transaction/payment').single;
      expect(geld.beginn.isBefore(diagnose.ende!), isFalse);
      expect(richtig.hoechstGleichzeitig, 1);
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
