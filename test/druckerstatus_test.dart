import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ablehnen.dart';
import 'support/agent_klient.dart';
import 'support/druck_aufbau.dart';
import 'support/fake_epos.dart';
import 'support/fake_printer.dart';

/// `DLE EOT`-Antworten (feste Bits 0x12 plus die gemeldeten Bits).
const int _ok = 0x12;
const int _deckelOffen = 0x12 | 0x04;
const int _stoppPapierende = 0x12 | 0x20;
const int _rolleLeer = 0x12 | 0x60;
const int _rolleFastLeer = 0x12 | 0x0C;

/// Der Statusabruf über ePOS ist eine HTTP-Anfrage; unter Last (viele
/// Testdateien zugleich) braucht sie länger als die 500 ms im Betrieb. Dann
/// gälte der Zustand zu Recht als unbekannt – hier soll er ankommen.
const Duration _eposBudget = Duration(seconds: 3);

void main() {
  group('DLE EOT deuten (Epson ESC/POS, DLE EOT 2 und 4)', () {
    final faelle = <(int?, int?), (Papier, Deckel)>{
      (_ok, _ok): (Papier.ok, Deckel.zu),
      (_deckelOffen, _ok): (Papier.ok, Deckel.offen),
      // Papierende nur doppelt belegt: Rollensensor leer UND Stopp wegen
      // Papierende. Der Sensor allein ist unbekannt und sperrt nie.
      (_stoppPapierende, _rolleLeer): (Papier.leer, Deckel.zu),
      (_ok, _rolleLeer): (Papier.unbekannt, Deckel.zu),
      (_ok, _rolleFastLeer): (Papier.fastLeer, Deckel.zu),
      (_stoppPapierende, 0x12 | 0x6C): (Papier.leer, Deckel.zu),
      (_ok, 0x12 | 0x6C): (Papier.unbekannt, Deckel.zu),
      // Nur ein Bit eines Paares: nicht plausibel, also nicht gemeldet.
      (_ok, 0x12 | 0x20): (Papier.ok, Deckel.zu),
      (_ok, 0x12 | 0x40): (Papier.ok, Deckel.zu),
      (_ok, 0x12 | 0x04): (Papier.ok, Deckel.zu),
      // Ohne Rollensensor: Stopp wegen Papierende aus DLE EOT 2.
      (_stoppPapierende, null): (Papier.leer, Deckel.zu),
      (_ok, null): (Papier.unbekannt, Deckel.zu),
      // Falsche feste Bits zählen nie.
      (0x04, 0x60): (Papier.unbekannt, Deckel.unbekannt),
      (0x93, 0xF3): (Papier.unbekannt, Deckel.unbekannt),
      (null, null): (Papier.unbekannt, Deckel.unbekannt),
      (null, _rolleLeer): (Papier.unbekannt, Deckel.unbekannt),
    };
    faelle.forEach((roh, erwartet) {
      test('$roh → $erwartet', () {
        final zustand = zustandAusDleEot(
          offlineGrund: roh.$1,
          rollensensor: roh.$2,
        );
        expect(zustand.papier, erwartet.$1);
        expect(zustand.deckel, erwartet.$2);
      });
    });
  });

  group('ePOS-Statusbits', () {
    final faelle = <String, (Papier, Deckel)>{
      '2': (Papier.ok, Deckel.zu),
      '${0x00080000 | 2}': (Papier.leer, Deckel.zu),
      '${0x00020000 | 2}': (Papier.fastLeer, Deckel.zu),
      '${0x00000020 | 8}': (Papier.ok, Deckel.offen),
      '251658262': (Papier.ok, Deckel.zu),
      '1': (Papier.unbekannt, Deckel.unbekannt),
      '': (Papier.unbekannt, Deckel.unbekannt),
      'kaputt': (Papier.unbekannt, Deckel.unbekannt),
      '-4': (Papier.unbekannt, Deckel.unbekannt),
    };
    faelle.forEach((status, erwartet) {
      test('"$status" → $erwartet', () {
        final zustand = zustandAusEposStatus(status);
        expect(zustand.papier, erwartet.$1);
        expect(zustand.deckel, erwartet.$2);
      });
    });
  });

  group('Sperre', () {
    test('nur Papierende und offener Deckel blockieren', () {
      expect(
        const DruckerZustand(papier: Papier.fastLeer, deckel: Deckel.zu).sperre,
        isNull,
      );
      expect(DruckerZustand.unbekannt.sperre, isNull);
      final leer = const DruckerZustand(
        papier: Papier.leer,
        deckel: Deckel.offen,
      ).sperre!;
      expect(leer.code, errorPaperOut, reason: 'Papierende zuerst');
      expect(leer.message, 'Drucker: Papier leer – neue Rolle einlegen.');
      expect(leer.mayHavePrinted, isFalse);
      final deckel = const DruckerZustand(
        papier: Papier.ok,
        deckel: Deckel.offen,
      ).sperre!;
      expect(deckel.code, errorCoverOpen);
      expect(deckel.message, 'Drucker: Deckel offen – bitte schließen.');
    });

    test(
      'ein unveränderter Zustand meldet kein zweites printer.state',
      () async {
        final bus = EventBus();
        addTearDown(bus.close);
        final gesehen = <AgentEvent>[];
        final abo = bus.stream.listen(gesehen.add);
        addTearDown(abo.cancel);
        final temp = Directory.systemTemp.createTempSync('connect-zustand-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final registry = PrinterRegistry(
          store: ConfigStore.forDirectory(temp),
          events: bus,
        );
        final jetzt = DateTime.utc(2026, 11, 10, 9);
        const fastLeer = DruckerZustand(
          papier: Papier.fastLeer,
          deckel: Deckel.zu,
          bereitschaft: Bereitschaft.bereit,
        );
        registry
          ..noteZustand('p1', fastLeer, jetzt)
          ..noteZustand(
            'p1',
            const DruckerZustand(
              papier: Papier.fastLeer,
              deckel: Deckel.zu,
              bereitschaft: Bereitschaft.bereit,
            ),
            jetzt,
          )
          ..noteZustand('p1', DruckerZustand.nichtBereit, jetzt);
        await Future<void>.delayed(Duration.zero);
        expect(gesehen.map((e) => e.data['readiness']), <String>[
          'ready',
          'not_ready',
        ]);
        expect(fastLeer.toString(), contains('near_end'));
      },
    );

    test('Vertragsnamen', () {
      expect(Papier.values.map((p) => p.wireName), <String>[
        'ok',
        'near_end',
        'out',
        'unknown',
      ]);
      expect(Deckel.values.map((d) => d.wireName), <String>[
        'closed',
        'open',
        'unknown',
      ]);
    });
  });

  group('vor dem Druck (9100)', () {
    late DruckAufbau a;
    late FakeTcpPrinter drucker;

    setUp(() async {
      a = DruckAufbau.erstellen();
      drucker = await FakeTcpPrinter.start(
        dleEot: const <int, int>{2: _ok, 4: _ok},
      );
    });

    tearDown(() async {
      await drucker.stop();
      await a.aufraeumen();
    });

    Future<PrintResult> drucke(String id, {String jobId = 'job'}) async {
      final vorher = drucker.druckVerbindungen.length;
      final ergebnis = await a.queue.enqueue(id, jobId, beispielBon);
      if (ergebnis.ok) await drucker.warteAufDruck(vorher);
      return ergebnis;
    }

    test('Papier leer: kein Byte des Bons, paper_out; nach dem Einlegen geht '
        'derselbe Auftrag', () async {
      final id = await a.drucker(drucker.port);
      drucker.dleEot
        ..[2] = _stoppPapierende
        ..[4] = _rolleLeer;
      final ergebnis = await drucke(id, jobId: 'beleg-7');
      expect(ergebnis.ok, isFalse);
      expect(ergebnis.code, errorPaperOut);
      expect(ergebnis.mayHavePrinted, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(drucker.druckVerbindungen, isEmpty);
      final eintrag = (await a.registry.summaries()).single;
      expect(eintrag['paper'], 'out');
      expect(eintrag['state'], 'online');

      drucker.dleEot
        ..[2] = _ok
        ..[4] = _ok;
      final nochmal = await drucke(id, jobId: 'beleg-7');
      expect(nochmal.ok, isTrue, reason: 'nicht als erledigt gemerkt');
      expect(drucker.druckVerbindungen.single, beispielBon);
    });

    test('Deckel offen: cover_open, kein Byte', () async {
      final id = await a.drucker(drucker.port);
      drucker.dleEot[2] = _deckelOffen;
      final ergebnis = await drucke(id);
      expect(ergebnis.code, errorCoverOpen);
      expect(drucker.druckVerbindungen, isEmpty);
    });

    test('fast leer: es wird gedruckt, Zustand near_end', () async {
      final id = await a.drucker(drucker.port);
      drucker.dleEot[4] = _rolleFastLeer;
      expect((await drucke(id)).ok, isTrue);
      expect((await a.registry.summaries()).single['paper'], 'near_end');
    });

    test('Antwort ohne feste Bits: unbekannt, es wird gedruckt', () async {
      final id = await a.drucker(drucker.port);
      drucker.dleEot
        ..[2] = 0x04
        ..[4] = 0x60;
      expect((await drucke(id)).ok, isTrue);
      expect(drucker.druckVerbindungen.single, beispielBon);
    });

    test('printer_status aus: keine Abfrage, auch bei leerem Papier', () async {
      await a.abschalten(<Neuerung>[Neuerung.druckerStatus]);
      final id = await a.drucker(drucker.port);
      drucker.dleEot
        ..[2] = _stoppPapierende
        ..[4] = _rolleLeer;
      expect((await drucke(id)).ok, isTrue);
      expect(drucker.abfrageVerbindungen, isEmpty);
    });

    test('Kennung und Status in einer Abfrage-Verbindung', () async {
      final id = await a.drucker(drucker.port, serial: 'X5ZT000123');
      drucker.gsI[68] = 'X5ZT000123';
      expect((await drucke(id)).ok, isTrue);
      expect(drucker.abfrageVerbindungen.single, <int>[
        ...dleEot(2),
        ...dleEot(4),
        ...gsI(68),
      ]);
    });

    test('Konflikt ohne Fund: der Bon ginge an das Gerät unter der Adresse – '
        'dessen Papierende sperrt', () async {
      final id = await a.drucker(drucker.port, serial: 'X5ZT000123');
      drucker
        ..gsI[68] = 'X5ZT000999'
        ..dleEot[2] = _stoppPapierende
        ..dleEot[4] = _rolleLeer;
      final ergebnis = await drucke(id);
      expect(ergebnis.code, errorPaperOut);
      expect(drucker.druckVerbindungen, isEmpty);
      expect(a.registry.lagen.von(id).kennung, KennungsLage.konflikt);

      // Papier nachgelegt: gedruckt wird an die eingerichtete Adresse wie bis
      // 1.4.2, der Konflikt bleibt sichtbar.
      drucker.dleEot
        ..[2] = _ok
        ..[4] = _ok;
      expect((await drucke(id, jobId: 'job-2')).ok, isTrue);
      expect(a.registry.lagen.von(id).kennung, KennungsLage.konflikt);
    });
  });

  group('vor dem Druck (ePOS)', () {
    late DruckAufbau a;
    late FakeEposServer epos;

    tearDown(() async {
      await epos.stop();
      await a.aufraeumen();
    });

    Future<String> eposDrucker() async {
      await a.store.mutate(
        (c) => c.copyWith(
          printers: <PrinterConfig>[
            PrinterConfig(
              id: 'p_epos',
              name: 'ePOS',
              kind: PrinterKind.epos,
              host: '127.0.0.1',
              port: epos.port,
            ),
          ],
        ),
      );
      return 'p_epos';
    }

    bool istDruck(String rumpf) => rumpf.contains('<command>');

    test(
      'Papierende in den Statusbits: kein Druckauftrag, paper_out',
      () async {
        a = DruckAufbau.erstellen(budget: _eposBudget);
        epos = await FakeEposServer.start(status: '${0x00080000 | 2}');
        final id = await eposDrucker();
        final ergebnis = await a.queue.enqueue(id, 'job', beispielBon);
        expect(ergebnis.code, errorPaperOut);
        expect(epos.bodies.where(istDruck), isEmpty);
        expect(epos.bodies, hasLength(1), reason: 'nur der Statusabruf');
      },
    );

    test('fast leer: Druck geht, near_end', () async {
      a = DruckAufbau.erstellen(budget: _eposBudget);
      epos = await FakeEposServer.start(status: '${0x00020000 | 2}');
      final id = await eposDrucker();
      expect((await a.queue.enqueue(id, 'job', beispielBon)).ok, isTrue);
      expect(epos.bodies.where(istDruck), hasLength(1));
      expect(epos.lastCommand, beispielBon);
      expect((await a.registry.summaries()).single['paper'], 'near_end');
    });

    test('Statusabruf scheitert (HTTP 500): unbekannt, gedruckt wird '
        'wie bisher', () async {
      a = DruckAufbau.erstellen(budget: _eposBudget);
      epos = await FakeEposServer.start(mode: FakeEposMode.serverError);
      final id = await eposDrucker();
      final ergebnis = await a.queue.enqueue(id, 'job', beispielBon);
      // Der Druck selbst scheitert am Fake wie in 1.4.2 – nicht an der
      // Statusprüfung.
      expect(ergebnis.code, errorPrinterOffline);
      expect(epos.bodies.where(istDruck), isNotEmpty);
    });
  });

  group('Statustakt und Abfrage auf Zuruf', () {
    late DruckAufbau a;
    late FakeTcpPrinter drucker;
    late DruckerStatusDienst dienst;
    DateTime? kasse;
    late List<String> verfehlt;

    setUp(() async {
      a = DruckAufbau.erstellen();
      drucker = await FakeTcpPrinter.start(
        dleEot: const <int, int>{2: _ok, 4: _rolleFastLeer},
      );
      kasse = null;
      verfehlt = <String>[];
      dienst = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => kasse,
        clock: () => a.jetzt,
        log: a.log,
        budget: const Duration(milliseconds: 500),
      )..beiDauerndVerfehlt = verfehlt.add;
    });

    tearDown(() async {
      await dienst.stop();
      await drucker.stop();
      await a.aufraeumen();
    });

    test('ohne offene Kasse kein Takt', () async {
      await a.drucker(drucker.port);
      await dienst.runde();
      expect(dienst.runden, 0);
      expect(drucker.connections, 0);

      kasse = a.jetzt.subtract(kasseOffenFenster + const Duration(seconds: 1));
      await dienst.runde();
      expect(drucker.connections, 0, reason: 'zu lange her');
    });

    test(
      'offene Kasse: jeder Drucker einmal je Runde, Zustand gemerkt',
      () async {
        await a.drucker(drucker.port);
        final zweiter = await FakeTcpPrinter.start(
          dleEot: const <int, int>{2: _deckelOffen, 4: _ok},
        );
        addTearDown(zweiter.stop);
        await a.drucker(zweiter.port, id: 'p_zweiter');
        kasse = a.jetzt;

        await dienst.runde();
        expect(drucker.abfrageVerbindungen.single, <int>[
          ...dleEot(2),
          ...dleEot(4),
        ]);
        expect(zweiter.abfrageVerbindungen, hasLength(1));
        final liste = await a.registry.summaries();
        expect(liste.first['paper'], 'near_end');
        expect(liste.last['cover'], 'open');
        expect(liste.first['statusAt'], isNotNull);
      },
    );

    test('gleichzeitige Runden laufen als eine', () async {
      await a.drucker(drucker.port);
      kasse = a.jetzt;
      await Future.wait(<Future<void>>[
        dienst.runde(),
        dienst.runde(),
        dienst.runde(),
      ]);
      expect(dienst.runden, 1);
      expect(drucker.connections, 1);
    });

    test('status_poll aus: keine Runde', () async {
      await a.abschalten(<Neuerung>[Neuerung.statusTakt]);
      await a.drucker(drucker.port);
      kasse = a.jetzt;
      await dienst.runde();
      expect(drucker.connections, 0);
    });

    test('zweimal nicht gesehen: genau einmal Suche anstoßen', () async {
      // Eigener Dienst, dessen Verbindungen zur toten Adresse scheitern.
      final dienst = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(verbinden: verbindenOhneTote),
        kasseZuletzt: () => kasse,
        clock: () => a.jetzt,
      )..beiDauerndVerfehlt = verfehlt.add;
      await a.drucker(9100, host: toteAdresse);
      kasse = a.jetzt;
      await dienst.runde();
      expect(verfehlt, isEmpty);
      await dienst.runde();
      expect(verfehlt, <String>['p_ab12cd34']);
      await dienst.runde();
      expect(verfehlt, hasLength(1));
      expect(
        (await a.registry.summaries()).single['state'],
        PrinterState.offline.wireName,
      );
    });

    test('stummes Gerät: der Takt prüft nur noch die Erreichbarkeit', () async {
      drucker.dleEot.clear();
      await a.drucker(drucker.port);
      kasse = a.jetzt;
      await dienst.runde();
      expect(drucker.abfrageVerbindungen, hasLength(1));
      await dienst.runde();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(drucker.connections, 2);
      expect(drucker.abfrageVerbindungen, hasLength(1), reason: 'kein Byte');
    });

    test('ePOS im Takt: Statusbits, ohne Antwort offline', () async {
      final epos = await FakeEposServer.start(status: '${0x00020000 | 2}');
      addTearDown(epos.stop);
      await a.store.mutate(
        (c) => c.copyWith(
          printers: <PrinterConfig>[
            PrinterConfig(
              id: 'p_epos',
              name: 'ePOS',
              kind: PrinterKind.epos,
              host: '127.0.0.1',
              port: epos.port,
            ),
          ],
        ),
      );
      kasse = a.jetzt;
      final langsam = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => kasse,
        clock: () => a.jetzt,
        budget: _eposBudget,
      );
      await langsam.runde();
      var eintrag = (await a.registry.summaries()).single;
      expect(eintrag['paper'], 'near_end');
      expect(eintrag['state'], 'online');
      final kaputt = await FakeEposServer.start(mode: FakeEposMode.serverError);
      addTearDown(kaputt.stop);
      await a.store.mutate(
        (c) => c.copyWith(
          printers: <PrinterConfig>[
            c.printers.single.copyWith(port: kaputt.port),
          ],
        ),
      );
      await langsam.runde();
      eintrag = (await a.registry.summaries()).single;
      expect(eintrag['state'], 'offline');
    });

    test('auf Zuruf: sofort, mit Papier und Deckel', () async {
      final id = await a.drucker(drucker.port);
      final eintrag = await dienst.jetzt(id);
      expect(eintrag!['paper'], 'near_end');
      expect(eintrag['cover'], 'closed');
      expect(eintrag['state'], 'online');
      expect(await dienst.jetzt('p_gibtsnicht'), isNull);
    });

    test('der Timer dreht Runden im Abstand', () async {
      final schnell = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => DateTime.now(),
        abstand: const Duration(milliseconds: 30),
      );
      await a.drucker(drucker.port);
      schnell.start();
      await warteBis(() async => schnell.runden >= 2, grund: 'zwei Runden');
      await schnell.stop();
    });
  });

  group('über die API', () {
    late Directory temp;
    late Agent agent;
    late FakeTcpPrinter drucker;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('connect-status-api-');
      drucker = await FakeTcpPrinter.start(
        dleEot: const <int, int>{2: _stoppPapierende, 4: _rolleLeer},
      );
      agent = Agent(
        store: ConfigStore.forDirectory(temp),
        log: AgentLog(Directory(p.join(temp.path, 'logs'))),
        preferredPort: 0,
        openBrowser: false,
        environment: const <String, String>{},
      );
      await agent.start();
    });

    tearDown(() async {
      await agent.stop();
      await drucker.stop();
      temp.deleteSync(recursive: true);
    });

    test('POST /v1/printers/{id}/status und printer.state mit paper', () async {
      final ereignisse = <AgentEvent>[];
      final abo = agent.events.stream.listen(ereignisse.add);
      addTearDown(abo.cancel);
      final drucker1 = await agent.printers.upsert(
        PrinterConfig(
          id: '',
          name: 'Bon',
          kind: PrinterKind.tcp9100,
          host: '127.0.0.1',
          port: drucker.port,
        ),
      );
      final token = await agent.context.pairing.issueToken();
      final antwort = await anAgent(
        agent.port,
        'POST',
        '/v1/printers/${drucker1.id}/status',
        token: token,
      );
      final eintrag = antwort.json['printer']! as Map<String, Object?>;
      expect(eintrag['paper'], 'out');
      expect(eintrag['cover'], 'closed');
      final unbekannt = await anAgent(
        agent.port,
        'POST',
        '/v1/printers/p_gibtsnicht/status',
        token: token,
      );
      expect(unbekannt.code, errorPrinterUnknown);
      await Future<void>.delayed(Duration.zero);
      final mitPapier = ereignisse.where(
        (e) => e.type == eventPrinterState && e.data['paper'] == 'out',
      );
      expect(mitPapier, isNotEmpty);
    });
  });
}
