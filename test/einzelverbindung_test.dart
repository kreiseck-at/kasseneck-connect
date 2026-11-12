import 'dart:async';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

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
}
