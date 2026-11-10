import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';

const String _serie = 'X5ZT000123';
const String _mac = '00:26:ab:00:00:01';
const Map<int, int> _gesund = <int, int>{2: 0x12, 4: 0x12};

void main() {
  late DruckAufbau a;
  late FakeTcpPrinter drucker;

  setUp(() async {
    a = DruckAufbau.erstellen();
    drucker = await FakeTcpPrinter.start(
      dleEot: _gesund,
      gsI: const <int, String>{67: 'TM-m30III', 68: _serie},
    );
  });

  tearDown(() async {
    await drucker.stop();
    await a.aufraeumen();
  });

  KennungsLage lage(String id) => a.registry.lagen.von(id).kennung;

  /// Druckt und wartet, bis [ziel] (Vorgabe: [drucker]) den Bon gelesen hat.
  Future<PrintResult> drucke(String id, {FakeTcpPrinter? ziel}) async {
    final empfaenger = ziel ?? drucker;
    final vorher = empfaenger.druckVerbindungen.length;
    final ergebnis = await a.drucke(id);
    if (ergebnis.ok) await empfaenger.warteAufDruck(vorher);
    return ergebnis;
  }

  test('MAC passt: keine Abfrage-Verbindung, Druck byte-gleich', () async {
    final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
    a.arpMac = '0:26:ab:0:0:1';
    final ergebnis = await drucke(id);
    expect(ergebnis.ok, isTrue);
    expect(drucker.verbindungen, hasLength(1));
    expect(drucker.druckVerbindungen.single, beispielBon);
    expect(lage(id), KennungsLage.bestaetigt);
  });

  test('MAC weicht ab, Seriennummer passt: Druck, MAC nachgezogen', () async {
    final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
    a.arpMac = '00:26:ab:00:00:07';
    expect((await drucke(id)).ok, isTrue);
    expect(drucker.abfrageVerbindungen.single, <int>[...dleEot(2), ...gsI(68)]);
    expect(drucker.druckVerbindungen.single, beispielBon);
    final gespeichert = (await a.store.load()).printers.single;
    expect(gespeichert.mac, '00:26:ab:00:00:07');
    expect(gespeichert.serial, _serie);
    expect(lage(id), KennungsLage.bestaetigt);
  });

  test('andere Seriennummer: Konflikt, Druck an die eingerichtete Adresse '
      'wie 1.4.2, die fremde Kennung wird nicht übernommen', () async {
    final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
    a.arpMac = '00:26:ab:00:00:09';
    drucker.gsI[68] = 'X5ZT000999';

    final ergebnis = await drucke(id);
    expect(ergebnis.ok, isTrue, reason: 'nie blockieren');
    expect(drucker.druckVerbindungen.single, beispielBon);
    expect(lage(id), KennungsLage.konflikt);
    final gespeichert = (await a.store.load()).printers.single;
    expect(gespeichert.serial, _serie);
    expect(gespeichert.mac, _mac);
    expect(
      a.logZeilen.where((z) => z.contains('antwortet ein anderer Drucker')),
      hasLength(1),
    );
    final eintrag = (await a.registry.summaries()).single;
    expect((eintrag['identity']! as Map<String, Object?>)['state'], 'conflict');

    // Derselbe Konflikt wird nicht bei jedem Bon neu gemeldet.
    await drucke(id);
    expect(
      a.logZeilen.where((z) => z.contains('antwortet ein anderer Drucker')),
      hasLength(1),
    );
  });

  test('andere MAC ohne gespeicherte Seriennummer: unbekannt, Druck', () async {
    final id = await a.drucker(drucker.port, mac: _mac);
    a.arpMac = '00:26:ab:00:00:09';
    expect((await drucke(id)).ok, isTrue);
    expect(drucker.abfrageVerbindungen, isEmpty);
    expect(lage(id), KennungsLage.unbekannt);
  });

  test('fremdes Netz: keine MAC, Seriennummer wird gefragt', () async {
    a.schnittstellen = const <LocalInterface>[
      LocalInterface(name: 'en0', address: '192.168.0.10'),
    ];
    final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
    a.arpMac = '00:26:ab:00:00:09';
    expect((await drucke(id)).ok, isTrue);
    expect(a.arpAufrufe, 0);
    expect(drucker.abfrageVerbindungen, hasLength(1));
    expect(lage(id), KennungsLage.bestaetigt);
  });

  test('frisch bestätigt und MAC unbekannt: keine Abfrage vor dem Bon, '
      'nach zehn Minuten wieder', () async {
    final id = await a.drucker(drucker.port, serial: _serie);
    await drucke(id);
    expect(drucker.abfrageVerbindungen, hasLength(1));
    await drucke(id);
    expect(drucker.abfrageVerbindungen, hasLength(1), reason: 'frisch');
    a.jetzt = a.jetzt.add(kennungFrisch);
    await drucke(id);
    expect(drucker.abfrageVerbindungen, hasLength(2));
    expect(drucker.druckVerbindungen, hasLength(3));
  });

  test('stummes Gerät: einmal gefragt, dann zehn Minuten nicht; '
      'Zuschlag unter 600 ms', () async {
    drucker.dleEot.clear();
    drucker.gsI.clear();
    final id = await a.drucker(drucker.port, serial: _serie);

    final uhr = Stopwatch()..start();
    expect((await drucke(id)).ok, isTrue);
    expect(uhr.elapsed, lessThan(const Duration(milliseconds: 600)));
    expect(drucker.abfrageVerbindungen, hasLength(1));

    uhr.reset();
    await drucke(id);
    expect(uhr.elapsed, lessThan(const Duration(milliseconds: 200)));
    expect(drucker.abfrageVerbindungen, hasLength(1), reason: 'stumm');

    a.jetzt = a.jetzt.add(stummDauer);
    await drucke(id);
    expect(drucker.abfrageVerbindungen, hasLength(2));
    for (final bon in drucker.druckVerbindungen) {
      expect(bon, beispielBon);
    }
  });

  test('ohne Kennung: keine Abfrage, ein Hinweis je Tag', () async {
    final id = await a.drucker(drucker.port);
    await drucke(id);
    await drucke(id);
    expect(drucker.abfrageVerbindungen, isEmpty);
    bool hinweis(String z) => z.contains('hat noch keine Kennung');
    expect(a.logZeilen.where(hinweis), hasLength(1));
    a.jetzt = a.jetzt.add(const Duration(days: 1));
    await drucke(id);
    expect(a.logZeilen.where(hinweis), hasLength(2));
  });

  test('printer_identity aus: weder arp noch Abfrage', () async {
    await a.abschalten(<Neuerung>[Neuerung.druckerKennung]);
    final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
    a.arpMac = '00:26:ab:00:00:09';
    drucker.gsI[68] = 'X5ZT000999';
    expect((await drucke(id)).ok, isTrue);
    expect(a.arpAufrufe, 0);
    expect(drucker.abfrageVerbindungen, isEmpty);
    expect(drucker.druckVerbindungen.single, beispielBon);
  });

  group('Konflikt und schnelles Wiederfinden', () {
    late FakeTcpPrinter eigener;

    setUp(() async {
      eigener = await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: _serie},
      );
      drucker.gsI[68] = 'X5ZT000999';
    });

    tearDown(() => eigener.stop());

    test('der eigene Drucker woanders: dort drucken', () async {
      final id = await a.drucker(drucker.port, serial: _serie);
      a.vorpruefung.schnellesWiederfinden = (d) async {
        a.wiederfindenAufrufe++;
        return d.copyWith(port: eigener.port);
      };
      expect((await drucke(id, ziel: eigener)).ok, isTrue);
      expect(drucker.druckVerbindungen, isEmpty);
      expect(eigener.druckVerbindungen.single, beispielBon);
    });

    test('nicht gefunden: eingerichtete Adresse, zehn Minuten keine neue '
        'Suche vor dem Bon', () async {
      final id = await a.drucker(drucker.port, serial: _serie);
      a.vorpruefung.schnellesWiederfinden = (_) async {
        a.wiederfindenAufrufe++;
        return null;
      };
      await drucke(id);
      await drucke(id);
      expect(a.wiederfindenAufrufe, 1);
      expect(drucker.druckVerbindungen, hasLength(2));
      a.jetzt = a.jetzt.add(konfliktSuchPause);
      await drucke(id);
      expect(a.wiederfindenAufrufe, 2);
    });

    test('printer_relocate aus: keine Suche', () async {
      await a.abschalten(<Neuerung>[Neuerung.druckerWiederfinden]);
      final id = await a.drucker(drucker.port, serial: _serie);
      a.vorpruefung.schnellesWiederfinden = (_) async {
        a.wiederfindenAufrufe++;
        return null;
      };
      await drucke(id);
      expect(a.wiederfindenAufrufe, 0);
      expect(drucker.druckVerbindungen.single, beispielBon);
    });

    test('Kennung wieder bestätigt hebt den Konflikt auf', () async {
      final id = await a.drucker(drucker.port, serial: _serie);
      await drucke(id);
      expect(lage(id), KennungsLage.konflikt);
      drucker.gsI[68] = _serie;
      a.jetzt = a.jetzt.add(kennungFrisch);
      await drucke(id);
      expect(lage(id), KennungsLage.bestaetigt);
      expect(a.registry.lagen.von(id).konfliktSerie, isNull);
    });
  });
}
