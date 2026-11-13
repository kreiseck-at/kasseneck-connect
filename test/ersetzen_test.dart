import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';
import 'support/virtuelles_netz.dart';

const Map<int, int> _gesund = <int, int>{2: 0x12, 4: 0x12};
const String _alteSerie = 'X5ZT000123';
const String _neueSerie = 'X5ZT000999';
const String _adresse = '192.168.0.50';

/// MAC des alten Druckers: ohne sie sucht Connect nicht gründlich (Bytes nur
/// an Geräte desselben Herstellers).
const String _alteMac = '00:26:ab:00:00:01';

/// Unter der Adresse eines Druckers steht dauerhaft ein anderer (Gerät
/// getauscht, die Kasse richtet nichts neu ein): nach drei Bons über
/// mindestens eine Stunde und wenn der alte nirgends zu finden ist, übernimmt
/// Connect die neue Kennung. Gedruckt wurde ohnehin an die Adresse.
void main() {
  late VirtuellesNetz netz;
  late DruckAufbau a;
  late FakeTcpPrinter neuer;
  late Kennungspflege pflege;

  setUp(() async {
    netz = VirtuellesNetz();
    a = DruckAufbau.erstellen(netz: netz);
    neuer = await FakeTcpPrinter.start(
      dleEot: _gesund,
      gsI: const <int, String>{67: bewiesenesTestModell, 68: _neueSerie},
    );
    netz.stelle(_adresse, 9100, neuer.port);
    pflege = Kennungspflege(
      store: a.store,
      queue: a.queue,
      lagen: a.registry.lagen,
      wiederfinder: a.wiederfinder,
      log: a.log,
      clock: () => a.jetzt,
      erkennung: DruckerErkennung(
        abfrage: EscPosAbfrage(verbinden: netz.verbinden),
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
      ),
    );
    a.vorpruefung.beiDauerhaftemKonflikt = pflege.ersetzen;
  });

  tearDown(() async {
    await pflege.erledigt();
    await a.aufraeumen();
    await neuer.stop();
  });

  Future<PrinterConfig> gespeichert() async =>
      (await a.store.load()).printers.single;

  Future<void> bons(String id, List<Duration> abstaende) async {
    for (final abstand in abstaende) {
      a.jetzt = a.jetzt.add(abstand);
      expect((await a.drucke(id)).ok, isTrue, reason: 'nie blockiert');
      await pflege.erledigt();
    }
  }

  test('drei Bons über eine Stunde, der alte nirgends: Kennung übernommen, '
      'relocations mit kind replaced', () async {
    final id = await a.drucker(
      9100,
      host: _adresse,
      serial: _alteSerie,
      mac: _alteMac,
    );
    await bons(id, const <Duration>[
      Duration.zero,
      Duration(minutes: 30),
      Duration(minutes: 31),
    ]);
    final eintrag = await gespeichert();
    expect(eintrag.serial, _neueSerie);
    expect(eintrag.model, bewiesenesTestModell);
    expect(eintrag.modelSource, KennungsQuelle.escpos);
    expect(eintrag.host, _adresse);
    expect(eintrag.statusCapableAt, isNull, reason: 'anderes Gerät');
    final wechsel = (await a.store.load()).relocations.single;
    expect(wechsel.toJson(), <String, Object?>{
      'at': a.jetzt.toUtc().toIso8601String(),
      'kind': 'replaced',
      'id': id,
      'from': _alteSerie,
      'to': _neueSerie,
    });
    expect(
      a.logZeilen.where((z) => z.contains('Kennung übernommen')),
      hasLength(1),
    );
    // Danach kein Konflikt mehr.
    a.jetzt = a.jetzt.add(const Duration(minutes: 20));
    expect((await a.drucke(id)).ok, isTrue);
    expect(a.registry.lagen.von(id).kennung, KennungsLage.bestaetigt);
  });

  test('drei Bons, aber kürzer als eine Stunde: nichts übernommen', () async {
    final id = await a.drucker(
      9100,
      host: _adresse,
      serial: _alteSerie,
      mac: _alteMac,
    );
    await bons(id, const <Duration>[
      Duration.zero,
      Duration(minutes: 10),
      Duration(minutes: 10),
      Duration(minutes: 10),
    ]);
    expect((await gespeichert()).serial, _alteSerie);
    expect((await a.store.load()).relocations, isEmpty);
  });

  test('eine Stunde, aber nur zwei Bons: nichts übernommen', () async {
    final id = await a.drucker(
      9100,
      host: _adresse,
      serial: _alteSerie,
      mac: _alteMac,
    );
    await bons(id, const <Duration>[Duration.zero, Duration(minutes: 90)]);
    expect((await gespeichert()).serial, _alteSerie);
  });

  test(
    'der alte Drucker ist anderswo: er zieht um, die Kennung bleibt',
    () async {
      final alter = await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: _alteSerie},
      );
      addTearDown(alter.stop);
      final id = await a.drucker(
        9100,
        host: _adresse,
        serial: _alteSerie,
        mac: _alteMac,
      );
      // Die ARP-Tabelle kennt .61 noch nicht (schnelle Suche ohne Fund);
      // der alte steht erst seit eben dort, die gründliche Suche findet ihn.
      await bons(id, const <Duration>[Duration.zero, Duration(minutes: 30)]);
      netz.stelle('192.168.0.61', 9100, alter.port, macNachKontakt: _alteMac);
      await bons(id, const <Duration>[Duration(minutes: 31)]);
      final eintrag = await gespeichert();
      expect(eintrag.serial, _alteSerie);
      expect(eintrag.host, '192.168.0.61');
      expect((await a.store.load()).relocations.single.art, GeraeteArt.drucker);
    },
  );

  test('während einer Zahlung wird nicht gesucht und nichts übernommen; '
      'danach schon', () async {
    final id = await a.drucker(
      9100,
      host: _adresse,
      serial: _alteSerie,
      mac: _alteMac,
    );
    a.zahlung = true;
    await bons(id, const <Duration>[
      Duration.zero,
      Duration(minutes: 30),
      Duration(minutes: 31),
    ]);
    expect((await gespeichert()).serial, _alteSerie);
    a.zahlung = false;
    await bons(id, const <Duration>[Duration(minutes: 5)]);
    expect((await gespeichert()).serial, _neueSerie);
  });
}
