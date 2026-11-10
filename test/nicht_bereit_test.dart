import 'dart:async';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';
import 'support/virtuelles_netz.dart';

/// Gerätetest TM-T20III (10.11.2026): mit offenem Deckel oder ohne Papier
/// nimmt der Drucker die Verbindung an und beantwortet `DLE EOT` gar nicht –
/// keine Statusbits, nur Schweigen. Ein Drucker, der schon gültig geantwortet
/// hat und jetzt schweigt, ist deshalb nicht bereit.
const Map<int, int> _gesund = <int, int>{1: 0x16, 2: 0x12, 3: 0x12, 4: 0x12};
const String _mac = '00:26:ab:00:00:01';

void main() {
  late DruckAufbau a;
  late FakeTcpPrinter drucker;
  final seit = DateTime.utc(2026, 11, 1, 9);

  setUp(() async {
    a = DruckAufbau.erstellen();
    drucker = await FakeTcpPrinter.start(dleEot: _gesund);
  });

  tearDown(() async {
    await drucker.stop();
    await a.aufraeumen();
  });

  /// Wie eine frühere Abfrage (Takt, voriger Bon): der Drucker schweigt
  /// schon [schweigenMindestdauer] am Stück.
  void schweigtSchon(String id) => a.registry.lagen
      .von(id)
      .schweigt(a.jetzt.subtract(schweigenMindestdauer));

  Future<PrintResult> drucke(String id, {String jobId = 'beleg-1'}) async {
    final vorher = drucker.druckVerbindungen.length;
    final ergebnis = await a.queue.enqueue(id, jobId, beispielBon);
    if (ergebnis.ok) await drucker.warteAufDruck(vorher);
    return ergebnis;
  }

  group('Deutung', () {
    test('Bereitschaft: Vertragsnamen und Sperre', () {
      expect(Bereitschaft.values.map((b) => b.wireName), <String>[
        'ready',
        'not_ready',
        'unknown',
      ]);
      final sperre = DruckerZustand.nichtBereit.sperre!;
      expect(sperre.code, errorPrinterNotReady);
      expect(sperre.mayHavePrinted, isFalse);
      expect(
        sperre.message,
        'Drucker nicht bereit – Deckel schließen und Papier prüfen.',
      );
      expect(
        zustandAusDleEot(offlineGrund: 0x12).bereitschaft,
        Bereitschaft.bereit,
      );
      expect(zustandAusDleEot().bereitschaft, Bereitschaft.unbekannt);
      expect(zustandAusEposStatus('2').bereitschaft, Bereitschaft.bereit);
    });

    test('statusCapableAt übersteht den Rundlauf, nie eine Neueinrichtung', () {
      final d = PrinterConfig(
        id: 'p1',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
        serial: 'X5ZT000123',
        mac: _mac,
        statusCapableAt: seit,
      );
      expect(PrinterConfig.fromJson(d.toJson()).statusCapableAt, seit);
      // So schickt die Kasse den Drucker beim erneuten Einrichten.
      final neu = PrinterConfig(
        id: 'p1',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
      );
      final gleich = PrinterRegistry.behalteKennung(d, neu);
      expect(gleich.statusCapableAt, isNull, reason: 'neu geprüft');
      expect(gleich.serial, 'X5ZT000123', reason: 'Kennung bleibt');
      expect(gleich.mac, _mac);
      final andere = PrinterRegistry.behalteKennung(
        d,
        neu.copyWith(host: '192.168.0.51'),
      );
      expect(andere.statusCapableAt, isNull);
      expect(andere.serial, isNull);
      final verworfen = PrinterRegistry.behalteKennung(
        d,
        neu,
        kennungVerwerfen: true,
      );
      expect(verworfen.serial, isNull);
      expect(verworfen.mac, isNull);
      expect(verworfen.statusCapableAt, isNull);
    });
  });

  group('vor dem Druck', () {
    test('statusfähig, gleiche MAC, schweigt seit 30 s am Stück: kein Byte, '
        'printer_not_ready, zwei Versuche auf neuer Verbindung', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      drucker.dleEot.clear(); // Deckel auf
      schweigtSchon(id);
      final ergebnis = await drucke(id);
      expect(ergebnis.ok, isFalse);
      expect(ergebnis.code, errorPrinterNotReady);
      expect(ergebnis.mayHavePrinted, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(drucker.druckVerbindungen, isEmpty);
      expect(drucker.abfrageVerbindungen, hasLength(bereitVersuche));
      final eintrag = (await a.registry.summaries()).single;
      expect(eintrag['readiness'], 'not_ready');
      expect(eintrag['state'], 'online', reason: 'erreichbar, nicht bereit');

      // Deckel zu: derselbe Auftrag geht gleich durch, ohne Wartezeit.
      drucker.dleEot.addAll(_gesund);
      final nochmal = await drucke(id);
      expect(nochmal.ok, isTrue);
      // Bereit: eine Abfrage-Verbindung, kein zweiter Versuch.
      expect(drucker.abfrageVerbindungen, hasLength(bereitVersuche + 1));
      expect(drucker.druckVerbindungen.single, beispielBon);
      expect((await a.registry.summaries()).single['readiness'], 'ready');
    });

    test('nie geantwortet und stumm: Druck wie 1.4.2', () async {
      final id = await a.drucker(drucker.port);
      drucker.dleEot.clear();
      expect((await drucke(id)).ok, isTrue);
      expect(drucker.druckVerbindungen.single, beispielBon);
    });

    test('die erste gültige Antwort macht den Drucker statusfähig', () async {
      final id = await a.drucker(drucker.port, mac: _mac);
      a.arpMac = _mac;
      expect((await drucke(id)).ok, isTrue);
      await a.registry.hintergrundErledigt();
      expect((await a.store.load()).printers.single.statusCapableAt, isNotNull);
      // Der eigene Bon ist längst gedruckt.
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      drucker.dleEot.clear();
      schweigtSchon(id);
      expect((await drucke(id, jobId: 'beleg-2')).code, errorPrinterNotReady);
    });

    test('Schweigen ohne lange Vorgeschichte (etwa ein Bon eines anderen '
        'Rechners): unbekannt, gedruckt wie 1.4.2; erst nach 30 s am Stück '
        'nicht bereit', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      drucker.dleEot.clear();
      expect((await drucke(id)).ok, isTrue, reason: 'erstes Schweigen');
      expect((await a.registry.summaries()).single['readiness'], 'unknown');
      // 10 s später, nach dem Nachlauf des eigenen Bons: noch zu kurz.
      a.jetzt = a.jetzt.add(const Duration(seconds: 10));
      expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
      a.jetzt = a.jetzt.add(schweigenMindestdauer);
      expect((await drucke(id, jobId: 'beleg-3')).code, errorPrinterNotReady);
    });

    test('eine gültige Antwort beendet das Schweigen', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      schweigtSchon(id);
      expect((await drucke(id)).ok, isTrue, reason: 'antwortet');
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      drucker.dleEot.clear();
      expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
    });

    test(
      'statusfähig und stumm, aber die Kennung ist nicht bestätigt (keine '
      'MAC, keine frische Seriennummer): unbekannt, Druck wie 1.4.2',
      () async {
        // Unter derselben Adresse kann ein getauschtes Gerät hängen, das nie
        // auf DLE EOT antwortet – sein Schweigen sagt nichts über den Deckel.
        final id = await a.drucker(drucker.port, statusCapableAt: seit);
        drucker.dleEot.clear();
        expect((await drucke(id)).ok, isTrue);
        expect(drucker.druckVerbindungen.single, beispielBon);
        expect((await a.registry.summaries()).single['readiness'], 'unknown');
      },
    );

    test('frisch über die Seriennummer bestätigt: Schweigen sperrt auch ohne '
        'MAC', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        serial: 'X5ZT000123',
      );
      drucker.gsI[68] = 'X5ZT000123';
      expect((await drucke(id)).ok, isTrue);
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      drucker.dleEot.clear();
      schweigtSchon(id);
      expect((await drucke(id, jobId: 'beleg-2')).code, errorPrinterNotReady);
      // Nach der Frische ist die Kennung wieder offen: unbekannt, Druck.
      a.jetzt = a.jetzt.add(kennungFrisch);
      expect((await drucke(id, jobId: 'beleg-3')).ok, isTrue);
    });

    test(
      'frisch bestätigt, jetzt aber eine andere MAC und stumm: wie 1.4.2',
      () async {
        final id = await a.drucker(
          drucker.port,
          statusCapableAt: seit,
          mac: _mac,
        );
        a.arpMac = _mac;
        expect((await drucke(id)).ok, isTrue);
        expect(a.registry.lagen.von(id).frisch(a.jetzt), isTrue);
        // Getauscht: ein anderes Gerät unter der Adresse, das schweigt.
        a.arpMac = '00:26:ab:00:00:09';
        drucker.dleEot.clear();
        a.jetzt = a.jetzt.add(const Duration(minutes: 1));
        expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
      },
    );

    test(
      'eine Antwort unter abweichender MAC macht nicht statusfähig',
      () async {
        final id = await a.drucker(drucker.port, mac: _mac);
        a.arpMac = '00:26:ab:00:00:09';
        expect((await drucke(id)).ok, isTrue);
        await a.registry.hintergrundErledigt();
        expect((await a.store.load()).printers.single.statusCapableAt, isNull);
      },
    );

    test('Neueinrichtung (PUT) setzt statusCapableAt zurück: ein getauschtes, '
        'stummes Gerät druckt wieder', () async {
      // Ersatzgerät unter derselben Adresse, MAC unbekannt (fremdes Netz).
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        serial: 'X5ZT000123',
      );
      drucker.dleEot.clear();
      final alt = (await a.store.load()).printers.single;
      await a.registry.upsert(
        PrinterConfig(
          id: alt.id,
          name: alt.name,
          kind: alt.kind,
          host: alt.host,
          port: alt.port,
        ),
      );
      final nach = (await a.store.load()).printers.single;
      expect(nach.statusCapableAt, isNull);
      expect(nach.serial, 'X5ZT000123');
      expect((await drucke(id)).ok, isTrue);
      expect(drucker.druckVerbindungen.single, beispielBon);
    });

    test('stumm, aber eine andere MAC unter der Adresse: wie 1.4.2', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = '00:26:ab:00:00:09';
      drucker.dleEot.clear();
      expect((await drucke(id)).ok, isTrue);
    });

    test('printer_status aus: statusfähig und stumm druckt trotzdem', () async {
      await a.abschalten(<Neuerung>[Neuerung.druckerStatus]);
      final id = await a.drucker(drucker.port, statusCapableAt: seit);
      drucker.dleEot.clear();
      expect((await drucke(id)).ok, isTrue);
      expect(drucker.abfrageVerbindungen, isEmpty);
    });

    test('nimmt keine Verbindung an: printer_offline wie 1.4.2, nicht '
        'not_ready', () async {
      final netz = DruckAufbau.erstellen(netz: VirtuellesNetz());
      addTearDown(netz.aufraeumen);
      final id = await netz.drucker(
        9100,
        host: '192.168.0.50',
        statusCapableAt: seit,
      );
      final ergebnis = await netz.queue.enqueue(id, 'beleg-1', beispielBon);
      expect(ergebnis.code, errorPrinterOffline);
    });
  });

  group('Statustakt', () {
    test('statusfähig und stumm: erst unbekannt, nach 30 s am Stück not_ready, '
        'nie „stumm“ gemerkt', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      final dienst = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => a.jetzt,
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
      );
      drucker.dleEot.clear();
      await dienst.runde();
      var eintrag = (await a.registry.summaries()).single;
      expect(eintrag['readiness'], 'unknown', reason: 'erst seit eben');
      // Die nächste Runde, länger als 30 s später: nicht bereit.
      a.jetzt = a.jetzt.add(schweigenMindestdauer);
      await dienst.runde();
      eintrag = (await a.registry.summaries()).single;
      expect(eintrag['readiness'], 'not_ready');
      expect(eintrag['state'], 'online');
      expect(a.registry.lagen.von(id).stumm(a.jetzt), isFalse);

      drucker.dleEot.addAll(_gesund);
      await dienst.runde();
      eintrag = (await a.registry.summaries()).single;
      expect(eintrag['readiness'], 'ready');
    });

    test('nie geantwortet: die erste gültige Antwort im Takt macht '
        'statusfähig', () async {
      final id = await a.drucker(drucker.port);
      final dienst = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(),
        kasseZuletzt: () => a.jetzt,
        clock: () => a.jetzt,
      );
      await dienst.runde();
      await a.registry.hintergrundErledigt();
      expect((await a.store.load()).printers.single.statusCapableAt, isNotNull);
      expect(id, isNotEmpty);
    });
  });
}
