import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/fake_hps.dart';
import 'support/fake_process_runner.dart';
import 'support/port_zu.dart';

const String _tid = '12345678';

/// Ein Port, auf dem sicher niemand annimmt (siehe `terminal_test.dart`).
Future<int> _geschlossenerPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  await erwartePortZu(() => Socket.connect('127.0.0.1', port));
  return port;
}

void main() {
  group('TID-Regeln (wie die Kasse)', () {
    test('tidBestaetigt', () {
      final faelle = <Object?, bool>{
        <String, Object?>{'responseCode': '0', 'tid': _tid}: true,
        <String, Object?>{'responseCode': 0}: true,
        <String, Object?>{'responseCode': '0', 'tid': '012345678'}: true,
        <String, Object?>{'responseCode': '0', 'tid': ''}: true,
        <String, Object?>{'responseCode': '100108', 'tid': _tid}: false,
        <String, Object?>{'responseCode': '100008'}: false,
        <String, Object?>{'responseCode': '0', 'tid': '87654321'}: false,
        <String, Object?>{'tid': _tid}: false,
        'kein Objekt': false,
        null: false,
      };
      faelle.forEach((antwort, erwartet) {
        expect(tidBestaetigt(antwort, _tid), erwartet, reason: '$antwort');
      });
    });

    test('tidNormal: führende Nullen weg, nur bei reinen Ziffern', () {
      final faelle = <String, String>{
        '03600335': '3600335',
        '0012345678': '12345678',
        '12345678': '12345678',
        ' 012 ': '12',
        '0': '0',
        '000': '0',
        '': '',
        'T0123': 'T0123',
      };
      faelle.forEach((roh, erwartet) {
        expect(tidNormal(roh), erwartet, reason: roh);
      });
    });

    test('terminalSerie: nur ein brauchbarer Text aus sn', () {
      expect(
        terminalSerie(<String, Object?>{'sn': 'P000000K00001'}),
        'P000000K00001',
      );
      expect(terminalSerie(<String, Object?>{'sn': ''}), isNull);
      expect(terminalSerie(<String, Object?>{'sn': 'mit leer'}), isNull);
      expect(terminalSerie(<String, Object?>{'sn': 42}), isNull);
      expect(terminalSerie(<String, Object?>{'mac': 'Unavailable'}), isNull);
      expect(terminalSerie('kein Objekt'), isNull);
    });

    test('umleitungsZiel', () {
      final jetzt = DateTime.utc(2026, 11, 10, 12);
      TerminalConfig gemerkt({
        String tid = _tid,
        DateTime? bestaetigt,
        String host = '192.168.0.61',
      }) => TerminalConfig(
        host: host,
        tid: tid,
        confirmedAt: bestaetigt ?? jetzt.subtract(const Duration(hours: 1)),
      );
      ({String host, int port})? ziel(TerminalConfig? g, {String tid = _tid}) =>
          umleitungsZiel(
            host: '192.168.0.60',
            port: 8080,
            tid: tid,
            gemerkt: g,
            jetzt: jetzt,
          );

      expect(ziel(gemerkt()), (host: '192.168.0.61', port: 8080));
      expect(ziel(gemerkt(), tid: '012345678'), isNotNull);
      expect(ziel(null), isNull);
      expect(ziel(gemerkt(tid: '87654321')), isNull);
      expect(ziel(gemerkt(host: '192.168.0.60')), isNull, reason: 'dieselbe');
      expect(
        ziel(gemerkt(bestaetigt: jetzt.subtract(umleitungHoechstalter))),
        isNotNull,
      );
      expect(
        ziel(
          gemerkt(
            bestaetigt: jetzt.subtract(
              umleitungHoechstalter + const Duration(seconds: 1),
            ),
          ),
        ),
        isNull,
      );
      expect(
        ziel(gemerkt(bestaetigt: jetzt.add(const Duration(minutes: 1)))),
        isNull,
        reason: 'Zeitpunkt in der Zukunft',
      );
      expect(
        ziel(TerminalConfig(host: '192.168.0.61', tid: _tid)),
        isNull,
        reason: 'nie bestätigt',
      );
    });
  });

  group('Belegung', () {
    test('ein langer Aufruf je Terminal; frei nach Freigabe oder Ablauf', () {
      var jetzt = DateTime(2026, 11, 10, 9);
      final belegung = TerminalBelegung(clock: () => jetzt);
      final a = belegung.belegen(
        tid: _tid,
        host: '192.168.0.60',
        port: 8080,
        art: LangerAufruf.zahlung,
      );
      expect(a, isNotNull);
      expect(
        belegung.belegen(
          tid: '012345678',
          host: '192.168.0.99',
          port: 8080,
          art: LangerAufruf.gutschrift,
        ),
        isNull,
        reason: 'dieselbe TID',
      );
      expect(belegung.belegt(host: '192.168.0.60', port: 8080), isTrue);
      expect(belegung.belegt(tid: '87654321'), isFalse);
      final b = belegung.belegen(
        tid: '87654321',
        host: '192.168.0.62',
        port: 8080,
        art: LangerAufruf.zahlung,
      );
      expect(b, isNotNull, reason: 'anderes Terminal');
      belegung
        ..freigeben(a!)
        ..freigeben(a);
      expect(belegung.belegt(tid: _tid), isFalse);
      expect(belegung.irgendeins, isTrue);
      jetzt = jetzt.add(belegungHoechstdauer + const Duration(seconds: 1));
      expect(belegung.irgendeins, isFalse, reason: 'läuft immer ab');
    });
  });

  group('über die Routen', () {
    late Directory temp;
    late ConfigStore store;
    late AgentContext ctx;
    late HttpServer server;
    late FakeHpsServer hps;
    late TerminalBelegung belegung;
    late String token;
    late DateTime jetzt;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('connect-umleitung-');
      store = ConfigStore.forDirectory(temp);
      final log = AgentLog(Directory(p.join(temp.path, 'logs')));
      jetzt = DateTime.now();
      ctx = AgentContext(
        store: store,
        log: log,
        startedAt: jetzt,
        environment: const <String, String>{},
        pairing: Pairing(
          store: store,
          log: log,
          runProcess: FakeProcessRunner().runner,
        ),
      );
      belegung = TerminalBelegung();
      server = await shelf_io.serve(
        buildHandler(
          ctx,
          extraRoutes: <RouteRegistrar>[
            terminalRoutes(
              belegung: belegung,
              bridge: HpsBridge(
                log: log,
                verbindungTimeout: const Duration(milliseconds: 500),
                zahlungTimeout: const Duration(seconds: 3),
                kurzTimeout: const Duration(seconds: 3),
              ),
            ),
          ],
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      ctx.port = server.port;
      token = await ctx.pairing.issueToken();
      hps = await FakeHpsServer.starten();
    });

    tearDown(() async {
      await server.close(force: true);
      await hps.stop();
      temp.deleteSync(recursive: true);
    });

    Future<void> merke({
      String tid = _tid,
      Duration alter = const Duration(minutes: 5),
    }) => store.mutate(
      (c) => c.copyWith(
        terminal: TerminalConfig(
          host: '127.0.0.1',
          port: hps.port,
          tid: tid,
          confirmedAt: jetzt.subtract(alter).toUtc(),
        ),
      ),
    );

    Future<AgentAntwort> zahle(int port, {String tid = _tid}) => anAgent(
      server.port,
      'POST',
      '/v1/terminal/payment',
      token: token,
      rumpf: <String, Object?>{
        'host': '127.0.0.1',
        'port': port,
        'tid': tid,
        'amountCents': 100,
        'transactionId': '${DateTime.now().microsecondsSinceEpoch}',
      },
    );

    test('die TID geht ohne führende Nullen ans Terminal (HPS lehnt '
        '03600335 ab, nimmt 3600335)', () async {
      final diagnose = await anAgent(
        server.port,
        'POST',
        '/v1/terminal/diagnosis',
        token: token,
        rumpf: <String, Object?>{
          'host': '127.0.0.1',
          'port': hps.port,
          'tid': '0$_tid',
        },
      );
      expect(diagnose.ok, isTrue, reason: diagnose.text);
      expect(hps.aufrufe.single.pfad, '/api/terminals/$_tid/diagnosis');
      final zahlung = await zahle(hps.port, tid: '00$_tid');
      expect(zahlung.ok, isTrue);
      final rumpf =
          jsonDecode(hps.an('/api/transaction/payment').single.rumpf)
              as Map<String, Object?>;
      expect((rumpf['transaction']! as Map<String, Object?>)['tid'], _tid);
    });

    test('Zahlung an tote Adresse: genau einmal an die bestätigte Adresse '
        'derselben TID; endpoint nennt sie', () async {
      await merke();
      final tot = await _geschlossenerPort();
      final antwort = await zahle(tot);
      expect(antwort.ok, isTrue, reason: antwort.text);
      expect(antwort.json['endpoint'], <String, Object?>{
        'host': '127.0.0.1',
        'port': hps.port,
        'relocated': true,
      });
      expect(hps.an('/api/transaction/payment'), hasLength(1));
    });

    test(
      'ohne Umleitung trägt die Antwort endpoint mit relocated: false',
      () async {
        final antwort = await zahle(hps.port);
        expect(antwort.json['endpoint'], <String, Object?>{
          'host': '127.0.0.1',
          'port': hps.port,
          'relocated': false,
        });
      },
    );

    test('andere TID, zu alt oder abgeschaltet: keine Umleitung', () async {
      final tot = await _geschlossenerPort();
      await merke(tid: '87654321');
      expect((await zahle(tot)).code, errorTerminalUnreachable);
      await merke(alter: umleitungHoechstalter + const Duration(minutes: 1));
      expect((await zahle(tot)).code, errorTerminalUnreachable);
      await merke();
      await store.mutate(
        (c) => c.copyWith(disabledFeatures: <String>['terminal_relocate']),
      );
      final aus = await zahle(tot);
      expect(aus.code, errorTerminalUnreachable);
      expect(aus.json.containsKey('endpoint'), isFalse, reason: 'wie 1.4.2');
      expect(hps.aufrufe, isEmpty);
    });

    test(
      'nach abgerissener Verbindung (terminal_offline) keine Wiederholung',
      () async {
        await merke();
        // Nimmt an und wirft die Verbindung sofort weg: der Ausgang ist offen.
        final wirftWeg = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(wirftWeg.close);
        wirftWeg.listen((s) => s.destroy());
        final antwort = await zahle(wirftWeg.port);
        expect(antwort.code, isNot(errorTerminalUnreachable));
        expect(hps.aufrufe, isEmpty, reason: 'nie zweimal zahlen');
        expect(
          (antwort.json['endpoint']! as Map<String, Object?>)['relocated'],
          isFalse,
        );
      },
    );

    test('nach Zeitablauf (timeout) keine Wiederholung', () async {
      await merke();
      // Nimmt an und antwortet nie.
      final stumm = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final offen = <Socket>[];
      stumm.listen(offen.add);
      addTearDown(() async {
        for (final s in offen) {
          s.destroy();
        }
        await stumm.close();
      });
      final antwort = await zahle(stumm.port);
      expect(antwort.code, errorTerminalTimeout);
      expect(hps.aufrufe, isEmpty);
    });

    group('terminal_busy', () {
      setUp(() {
        hps.verzoegerung['/api/transaction/payment'] = const Duration(
          seconds: 2,
        );
      });

      test('zweite Zahlung aus einem anderen Tab: sofort terminal_busy mit '
          '409, keine zweite Anfrage am Terminal', () async {
        var ersteFertig = false;
        final erste = zahle(hps.port).whenComplete(() => ersteFertig = true);
        await warteBis(
          () async => hps.an('/api/transaction/payment').isNotEmpty,
          grund: 'erste Zahlung am Terminal',
        );
        final zweite = await zahle(hps.port);
        expect(ersteFertig, isFalse, reason: 'sofort, nicht nach der ersten');
        expect(zweite.code, errorTerminalBusy);
        expect(zweite.detail, <String, Object?>{'terminalHttpStatus': 409});
        expect((await erste).ok, isTrue);
        expect(hps.an('/api/transaction/payment'), hasLength(1));
        expect(hps.hoechstGleichzeitig, 1);
        // Danach ist das Terminal wieder frei.
        expect((await zahle(hps.port)).ok, isTrue);
      });

      test('Diagnose und Test während der Zahlung: terminal_busy; Status '
          'und Abbruch gehen durch', () async {
        final zahlung = zahle(hps.port);
        await warteBis(
          () async => hps.an('/api/transaction/payment').isNotEmpty,
          grund: 'Zahlung am Terminal',
        );
        Future<AgentAntwort> rufe(String pfad, Map<String, Object?> rumpf) =>
            anAgent(server.port, 'POST', pfad, token: token, rumpf: rumpf);
        final ziel = <String, Object?>{'host': '127.0.0.1', 'port': hps.port};
        expect(
          (await rufe('/v1/terminal/diagnosis', {...ziel, 'tid': _tid})).code,
          errorTerminalBusy,
        );
        expect((await rufe('/v1/terminal/test', ziel)).code, errorTerminalBusy);
        expect(
          (await rufe('/v1/terminal/discover', <String, Object?>{})).code,
          errorTerminalBusy,
        );
        final tx = <String, Object?>{
          ...ziel,
          'tid': _tid,
          'transactionId': '42',
        };
        expect((await rufe('/v1/terminal/status', tx)).ok, isTrue);
        expect((await rufe('/v1/terminal/abort', tx)).ok, isTrue);
        await zahlung;
        expect(hps.an('/api/terminals/'), isEmpty);
      });

      test(
        'eine Diagnose, die vor der Zahlung begann, läuft zu Ende, bevor '
        'die Zahlung hinausgeht; eine hängende hält sie höchstens 2 s auf',
        () async {
          hps.verzoegerung['/api/terminals/'] = const Duration(
            milliseconds: 400,
          );
          Future<AgentAntwort> diagnose() => anAgent(
            server.port,
            'POST',
            '/v1/terminal/diagnosis',
            token: token,
            rumpf: <String, Object?>{
              'host': '127.0.0.1',
              'port': hps.port,
              'tid': _tid,
            },
          );
          final erste = diagnose();
          await warteBis(
            () async => hps.an('/api/terminals/').isNotEmpty,
            grund: 'Diagnose am Terminal',
          );
          hps.verzoegerung['/api/transaction/payment'] = Duration.zero;
          final zahlung = await zahle(hps.port);
          expect(zahlung.ok, isTrue);
          expect((await erste).ok, isTrue);
          final d = hps.an('/api/terminals/').single;
          final z = hps.an('/api/transaction/payment').single;
          expect(z.beginn.isBefore(d.ende!), isFalse, reason: 'nacheinander');

          // Hängt eine Diagnose, geht die Zahlung nach höchstens 2 s trotzdem.
          hps.verzoegerung['/api/terminals/'] = const Duration(seconds: 6);
          final haengt = diagnose();
          await warteBis(
            () async => hps.an('/api/terminals/').length == 2,
            grund: 'zweite Diagnose am Terminal',
          );
          final uhr = Stopwatch()..start();
          expect((await zahle(hps.port)).ok, isTrue);
          expect(uhr.elapsed, lessThan(kurzeAbwartenHoechstens * 2));
          expect(uhr.elapsed, greaterThanOrEqualTo(kurzeAbwartenHoechstens));
          await haengt;
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test('Aufhebung während der Zahlung: terminal_busy, nie ans Terminal '
          '(HPS 1.14.4 hing dabei 30 s)', () async {
        final zahlung = zahle(hps.port);
        await warteBis(
          () async => hps.an('/api/transaction/payment').isNotEmpty,
          grund: 'Zahlung am Terminal',
        );
        final aufhebung = await anAgent(
          server.port,
          'POST',
          '/v1/terminal/cancel',
          token: token,
          rumpf: <String, Object?>{
            'host': '127.0.0.1',
            'port': hps.port,
            'tid': _tid,
            'transactionId': '42',
            'amountCents': 100,
          },
        );
        expect(aufhebung.code, errorTerminalBusy);
        await zahlung;
        expect(hps.aufrufe.where((a) => a.methode == 'DELETE'), isEmpty);
      });

      test(
        'busy_lock aus: die zweite Zahlung geht ans Terminal wie 1.4.2',
        () async {
          await store.mutate(
            (c) => c.copyWith(disabledFeatures: <String>['busy_lock']),
          );
          final erste = zahle(hps.port);
          await warteBis(
            () async => hps.an('/api/transaction/payment').isNotEmpty,
            grund: 'erste Zahlung',
          );
          final zweite = await zahle(hps.port);
          await erste;
          expect(zweite.code, isNot(errorTerminalBusy));
          expect(hps.an('/api/transaction/payment'), hasLength(2));
        },
      );
    });
  });
}
