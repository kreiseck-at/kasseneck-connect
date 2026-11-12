import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/druck_aufbau.dart';
import 'support/fake_einzeldrucker.dart';

const String _mac = '00:26:ab:00:00:01';
const String _serie = 'X5ZT000123';

/// Ein Bon mit erkennbarem Namen (ESC @, Name, Schnitt).
Uint8List bon(String name) => Uint8List.fromList(<int>[
  0x1B,
  0x40,
  ...name.codeUnits,
  0x0A,
  0x1D,
  0x56,
  1,
]);

/// Der Name aus [bon].
String nameVon(List<int> bytes) =>
    String.fromCharCodes(bytes.sublist(2, bytes.length - 4));

/// Gerätetest 12.11.2026: Epson TM-T20III, zwei Connect an einem Drucker.
/// Der Drucker bedient nur eine Verbindung zugleich; weitere nimmt er an,
/// beantwortet sie aber nicht, solange ein anderer ihn hält.
///
/// Rot-Probe (vor den Änderungen gegen den Stand fec9f21 gelaufen):
/// * „Reihenfolge“: die Bons kamen als `[A3, A2, A1]` an.
/// * „Deckel offen“: `printer_not_ready` statt eines gedruckten Bons.
/// * „kein Flackern“: readiness fiel nach einer einzigen stummen Abfrage auf
///   `unknown`.
/// * „eine Runde“: zwei Verbindungen je Runde zu je rund 500 ms.
/// * „Takt nach eigenem Bon“: der Takt fragte direkt nach dem Bon.
/// * „zwei Connect“: `readinessHint` fehlte (Hinweis nie erfüllt).
void main() {
  late FakeEinzelDrucker fake;
  late DruckAufbau a;
  final seit = DateTime.utc(2026, 11, 1, 9);
  const id = 'p_ab12cd34';

  Future<void> einrichten(DruckAufbau x) async {
    x.arpMac = _mac;
    await x.drucker(
      fake.port,
      statusCapableAt: seit,
      mac: _mac,
      serial: _serie,
    );
  }

  DruckerStatusDienst dienst(
    DruckAufbau x, {
    Duration abstand = const Duration(hours: 1),
  }) => DruckerStatusDienst(
    registry: x.registry,
    queue: x.queue,
    abfrage: EscPosAbfrage(
      verbinden: fake.verbinden,
      aufbauGrenze: testAufbauGrenze,
    ),
    kasseZuletzt: () => x.jetzt,
    arp: x.arp,
    schnittstellen: () async => x.schnittstellen,
    clock: () => x.jetzt,
    abstand: abstand,
    // Großzügig wie in den übrigen Tests: unter Last steht eine
    // Loopback-Verbindung nicht immer in 200 ms.
    budget: testBudgetStatusfaehig,
  );

  Future<Map<String, Object?>> eintrag(DruckAufbau x) async =>
      (await x.registry.summaries()).single;

  setUp(() async {
    fake = await FakeEinzelDrucker.start(folge: Bedienfolge.neuesteZuerst);
    a = DruckAufbau.erstellen(verbinden: fake.verbinden);
    await einrichten(a);
  });

  tearDown(() async {
    await a.aufraeumen();
    await fake.stop();
  });

  group('Reihenfolge', () {
    test('die Bons eines Connect erreichen den Drucker in ihrer Reihenfolge, '
        'auch wenn ein anderer Rechner ihn gerade hält', () async {
      await fake.fremdBelegen(const Duration(seconds: 2));
      final uhr = Stopwatch()..start();
      final erster = await a.queue.enqueue(id, 'A1', bon('A1'));
      expect(erster.ok, isTrue, reason: '${erster.code}');
      // `ok` wie bis 1.4.2: Bytes geschrieben, Verbindung geschlossen – nicht
      // erst, wenn der Drucker sie bedient.
      expect(uhr.elapsed, lessThan(const Duration(milliseconds: 1500)));
      for (final name in <String>['A2', 'A3']) {
        final ergebnis = await a.queue.enqueue(id, name, bon(name));
        expect(ergebnis.ok, isTrue, reason: '$name: ${ergebnis.code}');
      }
      await fake.warteAufBons(3);
      expect(fake.bons.map(nameVon), <String>['A1', 'A2', 'A3']);
      expect(fake.hoechstBedient, 1);
    });

    test(
      'nicht bewiesenes Modell: kein Abwarten, Druck wie bis 1.4.2',
      () async {
        await a.drucker(fake.port, model: null);
        await fake.fremdBelegen(const Duration(seconds: 1));
        final uhr = Stopwatch()..start();
        for (final name in <String>['A1', 'A2']) {
          expect((await a.queue.enqueue(id, name, bon(name))).ok, isTrue);
        }
        // Beide zurück, bevor der Drucker frei war: niemand wartete.
        expect(uhr.elapsed, lessThan(const Duration(milliseconds: 800)));
        expect(fake.abfragen, hasLength(1), reason: 'nur die fremde');
        await fake.warteAufBons(2);
      },
    );
  });

  group('Reihenfolge: Grenzen', () {
    test('print_order aus: kein Abwarten, Druck wie bis 1.4.2', () async {
      await a.abschalten(<Neuerung>[Neuerung.druckReihenfolge]);
      await fake.fremdBelegen(const Duration(seconds: 2));
      final uhr = Stopwatch()..start();
      for (final name in <String>['A1', 'A2']) {
        expect((await a.queue.enqueue(id, name, bon(name))).ok, isTrue);
      }
      // Beide zurück, bevor der Drucker frei war: niemand wartete aufs Ende.
      expect(uhr.elapsed, lessThan(const Duration(milliseconds: 1800)));
      await fake.warteAufBons(2);
    });

    test(
      'die Kasse wartet nie länger als die Frist: hält ein anderer Rechner '
      'den Drucker länger, geht der nächste Bon danach wie bis 1.4.2',
      () async {
        final kurz = DruckAufbau.erstellen(
          verbinden: fake.verbinden,
          endeFrist: const Duration(milliseconds: 300),
        );
        addTearDown(kurz.aufraeumen);
        await einrichten(kurz);
        await fake.fremdBelegen(const Duration(seconds: 3));
        final uhr = Stopwatch()..start();
        for (final name in <String>['A1', 'A2']) {
          expect((await kurz.queue.enqueue(id, name, bon(name))).ok, isTrue);
        }
        expect(uhr.elapsed, lessThan(const Duration(seconds: 3)));
        await fake.warteAufBons(2);
      },
    );

    test('ein Drucker, der die Verbindung nie selbst beendet: nach zwei '
        'Fristen ohne Ende kein Abwarten mehr', () async {
      fake.schliesstSelbst = false;
      final kurz = DruckAufbau.erstellen(
        verbinden: fake.verbinden,
        endeFrist: const Duration(milliseconds: 300),
      );
      addTearDown(kurz.aufraeumen);
      await einrichten(kurz);
      for (final name in <String>['A1', 'A2', 'A3']) {
        expect((await kurz.queue.enqueue(id, name, bon(name))).ok, isTrue);
        // Eigener Bon druckt nicht mehr: die Vorprüfung fragt wieder.
        kurz.jetzt = kurz.jetzt.add(const Duration(minutes: 1));
      }
      await fake.warteAufBons(3);
      final lage = kurz.registry.lagen.von(id);
      expect(lage.endeGesehen, isFalse);
      expect(lage.beendetNichtSelbst, isTrue);
      expect(
        kurz.logZeilen.where((z) => z.contains('nicht selbst')),
        hasLength(1),
      );
      // Ab jetzt hält ein Bon die Kette nicht mehr auf.
      final uhr = Stopwatch()..start();
      final druck = kurz.queue.enqueue(id, 'A4', bon('A4'));
      expect((await druck).ok, isTrue);
      await kurz.queue.exclusive(id, () async {});
      expect(uhr.elapsed, lessThan(const Duration(milliseconds: 300)));
      await fake.warteAufBons(4);
      expect(fake.bons.map(nameVon), <String>['A1', 'A2', 'A3', 'A4']);
    });

    test('Ende vom Drucker gesehen: es bleibt beim Abwarten', () async {
      for (final name in <String>['A1', 'A2']) {
        expect((await a.queue.enqueue(id, name, bon(name))).ok, isTrue);
        await a.queue.exclusive(id, () async {});
      }
      expect(a.registry.lagen.von(id).endeGesehen, isTrue);
      expect(a.registry.lagen.von(id).beendetNichtSelbst, isFalse);
    });
  });

  group('Schweigen ist nur ein Hinweis', () {
    test('Deckel offen: der Bon wird nicht abgelehnt, readiness unknown mit '
        'Hinweis; nach dem Schließen gedruckt und wieder ready', () async {
      final d = dienst(a);
      await d.runde();
      expect((await eintrag(a))['readiness'], 'ready');

      fake.deckelAuf();
      // 35 s Schweigen, alle 5 s beobachtet (wie die Nachfragen bis jetzt).
      for (var s = 0; s <= 35; s += 5) {
        a.jetzt = a.jetzt.add(const Duration(seconds: 5));
        await d.runde();
      }
      final ergebnis = await a.queue.enqueue(id, 'A1', bon('A1'));
      expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
      final stumm = await eintrag(a);
      expect(stumm['readiness'], 'unknown');
      expect(stumm['readinessHint'], 'no_status_answer');
      expect(stumm['state'], 'online');
      await fake.warteBisRuhig();
      expect(fake.bons, isEmpty, reason: 'liegt im Puffer des Druckers');

      fake.deckelZu();
      expect(fake.bons.map(nameVon), <String>['A1']);
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      await d.runde();
      final wieder = await eintrag(a);
      expect(wieder['readiness'], 'ready');
      expect(wieder.containsKey('readinessHint'), isFalse);
    });

    test('kein Flackern: eine einzelne stumme Abfrage ändert nichts, erst die '
        'zweite in Folge zeigt den Hinweis', () async {
      final d = dienst(a);
      final zustaende = <Object?>[];
      final abo = a.events.stream
          .where((e) => e.type == eventPrinterState)
          .where((e) => e.data.containsKey('readiness'))
          .listen((e) => zustaende.add(e.data['readiness']));
      addTearDown(abo.cancel);
      await d.runde();
      expect((await eintrag(a))['readiness'], 'ready');

      // Eine stumme Abfrage (etwa: ein anderer Rechner hielt den Drucker).
      fake.deckelAuf();
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      await d.runde();
      var jetzt = await eintrag(a);
      expect(jetzt['readiness'], 'ready');
      expect(jetzt.containsKey('readinessHint'), isFalse);

      // Die nächste antwortet wieder: nichts ist je umgesprungen.
      fake.deckelZu();
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      await d.runde();
      await pumpEventQueue();
      expect(zustaende.where((z) => z != 'ready'), isEmpty);

      // Zwei stumme Abfragen in Folge: unbekannt mit Hinweis.
      fake.deckelAuf();
      for (var i = 0; i < 2; i++) {
        a.jetzt = a.jetzt.add(const Duration(minutes: 1));
        await d.runde();
      }
      jetzt = await eintrag(a);
      expect(jetzt['readiness'], 'unknown');
      expect(jetzt['readinessHint'], 'no_status_answer');
    });
  });

  group('Abfragen belegen den Drucker nicht', () {
    test(
      'eine Runde: eine kurze Verbindung, und keine Nachfrage von selbst',
      () async {
        final d = dienst(a)..start();
        addTearDown(d.stop);
        await d.runde();
        fake.deckelAuf();
        final vorher = fake.verbindungen.length;
        a.jetzt = a.jetzt.add(const Duration(minutes: 1));
        await d.runde();
        await fake.warteBisRuhig();
        final neu = fake.verbindungen.sublist(vorher);
        expect(neu, hasLength(1), reason: 'ein Versuch je Runde');
        expect(
          neu.single.gehalten,
          lessThan(const Duration(milliseconds: 480)),
          reason: 'kurzes Antwortfenster',
        );
        // 1.5.0 fragte bei Schweigen alle 5 s nach.
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(fake.verbindungen, hasLength(vorher + 1));
      },
    );

    test('der Takt fragt nicht, wenn vor ihm ein eigener Bon in der '
        'Warteschlange stand', () async {
      final d = dienst(a);
      final druck = a.queue.enqueue(id, 'A1', bon('A1'));
      final runde = d.runde();
      expect((await druck).ok, isTrue);
      await runde;
      await fake.warteAufBons(1);
      expect(fake.abfragen, hasLength(1), reason: 'nur die vor dem Bon');
    });

    test('der Takt streut: zwei Connect, die zugleich starten, fragen nicht '
        'dauerhaft im selben Augenblick', () {
      DruckerStatusDienst mitZufall(int saat) => DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => a.jetzt,
        random: Random(saat),
      );
      final x = mitZufall(1);
      final y = mitZufall(2);
      expect(x.streuung, const Duration(seconds: 15));
      final xs = List<Duration>.generate(20, (_) => x.naechsterAbstand());
      final ys = List<Duration>.generate(20, (_) => y.naechsterAbstand());
      for (final d in <Duration>[...xs, ...ys]) {
        expect(d, greaterThanOrEqualTo(statusTaktAbstand));
        expect(d, lessThan(statusTaktAbstand + x.streuung));
      }
      expect(xs.toSet(), hasLength(greaterThan(1)));
      // Aufsummiert laufen die beiden Takte auseinander.
      var vorsprung = Duration.zero;
      for (var i = 0; i < 20; i++) {
        vorsprung += xs[i] - ys[i];
      }
      expect(vorsprung, isNot(Duration.zero));
      // Ohne Streuung genau der Abstand.
      final fest = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => a.jetzt,
        streuung: Duration.zero,
      );
      expect(fest.naechsterAbstand(), statusTaktAbstand);
    });
  });

  group('zwei Connect an einem Drucker', () {
    late DruckAufbau b;
    final uhren = <Timer>[];

    /// Lässt die Uhr von [x] mitlaufen (die Statuslogik rechnet mit ihr);
    /// [versatz] springt vor.
    void laufendeUhr(DruckAufbau x, Duration Function() versatz) {
      final start = x.jetzt;
      final uhr = Stopwatch()..start();
      uhren.add(
        Timer.periodic(const Duration(milliseconds: 10), (_) {
          x.jetzt = start.add(uhr.elapsed + versatz());
        }),
      );
    }

    setUp(() async {
      b = DruckAufbau.erstellen(verbinden: fake.verbinden);
      await einrichten(b);
    });

    tearDown(() async {
      for (final uhr in uhren) {
        uhr.cancel();
      }
      uhren.clear();
      await b.aufraeumen();
    });

    test('kein falsches not_ready, kein abgelehnter Bon, alle gedruckt, je '
        'Connect in Reihenfolge; Deckel offen: Hinweis statt Ablehnung, '
        'nach dem Schließen ready', () async {
      var versatz = Duration.zero;
      laufendeUhr(a, () => versatz);
      laufendeUhr(b, () => versatz);
      final takt = const Duration(milliseconds: 300);
      final dA = dienst(a, abstand: takt)..start();
      final dB = dienst(b, abstand: takt)..start();
      addTearDown(dA.stop);
      addTearDown(dB.stop);
      final bereitschaft = <Object?>[];
      final abos = <StreamSubscription<AgentEvent>>[
        for (final x in <DruckAufbau>[a, b])
          x.events.stream
              .where((e) => e.type == eventPrinterState)
              .where((e) => e.data.containsKey('readiness'))
              .listen((e) => bereitschaft.add(e.data['readiness'])),
      ];
      addTearDown(() async {
        for (final abo in abos) {
          await abo.cancel();
        }
      });

      Future<List<PrintResult>> reihe(DruckAufbau x, String k, int n) async {
        final ergebnisse = <PrintResult>[];
        for (var i = 1; i <= n; i++) {
          ergebnisse.add(await x.queue.enqueue(id, '$k$i', bon('$k$i')));
          await Future<void>.delayed(Duration(milliseconds: 40 * i));
        }
        return ergebnisse;
      }

      final ergebnisse = await Future.wait(<Future<List<PrintResult>>>[
        reihe(a, 'A', 5),
        reihe(b, 'B', 5),
      ]);
      for (final e in ergebnisse.expand((e) => e)) {
        expect(e.ok, isTrue, reason: '${e.code} ${e.message}');
      }
      await fake.warteAufBons(10);
      final namen = fake.bons.map(nameVon).toList();
      expect(namen.where((n) => n.startsWith('A')), <String>[
        'A1', 'A2', 'A3', 'A4', 'A5', //
      ]);
      expect(namen.where((n) => n.startsWith('B')), <String>[
        'B1', 'B2', 'B3', 'B4', 'B5', //
      ]);

      // Deckel auf: beide Connect sehen nach zwei stummen Runden den Hinweis.
      versatz += const Duration(minutes: 1); // die Bons sind längst durch
      fake.deckelAuf();
      for (final x in <DruckAufbau>[a, b]) {
        await warteBis(
          () async => (await eintrag(x))['readinessHint'] == 'no_status_answer',
          frist: const Duration(seconds: 10),
          grund: 'Hinweis',
        );
        expect((await eintrag(x))['readiness'], 'unknown');
      }
      final offen = await Future.wait(<Future<PrintResult>>[
        a.queue.enqueue(id, 'A6', bon('A6')),
        b.queue.enqueue(id, 'B6', bon('B6')),
      ]);
      for (final e in offen) {
        expect(e.ok, isTrue, reason: 'nie abgelehnt: ${e.code}');
      }
      await fake.warteBisRuhig();
      expect(fake.bons, hasLength(10), reason: 'im Puffer');

      // Deckel zu: gepufferte Bons laufen, beide wieder bereit – binnen
      // einer Runde (die Uhr springt über den Nachlauf der Bons).
      fake.deckelZu();
      expect(fake.bons.map(nameVon).skip(10).toSet(), <String>{'A6', 'B6'});
      versatz += const Duration(minutes: 1);
      for (final x in <DruckAufbau>[a, b]) {
        await warteBis(
          () async => (await eintrag(x))['readiness'] == 'ready',
          frist: takt * 4,
          grund: 'wieder bereit',
        );
        expect((await eintrag(x)).containsKey('readinessHint'), isFalse);
      }
      expect(bereitschaft, isNot(contains('not_ready')));
      expect(fake.hoechstBedient, 1);
    });
  });
}
