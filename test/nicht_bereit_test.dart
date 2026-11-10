import 'dart:async';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';

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

    test('statusCapableAt übersteht den Rundlauf, eine neue Adresse von Hand '
        'verwirft es', () {
      final d = PrinterConfig(
        id: 'p1',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
        statusCapableAt: seit,
      );
      expect(PrinterConfig.fromJson(d.toJson()).statusCapableAt, seit);
      expect(d.ohneKennung().statusCapableAt, isNull);
      expect(
        PrinterRegistry.behalteKennung(d, d.ohneKennung()).statusCapableAt,
        seit,
      );
    });
  });

  group('vor dem Druck', () {
    test('statusfähig und jetzt stumm: kein Byte, printer_not_ready, zwei '
        'Versuche auf neuer Verbindung, höchstens 1,5 s', () async {
      final id = await a.drucker(drucker.port, statusCapableAt: seit);
      drucker.dleEot.clear(); // Deckel auf
      final uhr = Stopwatch()..start();
      final ergebnis = await drucke(id);
      expect(uhr.elapsed, lessThan(vorpruefungBudgetStatusfaehig + _spiel));
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
      final id = await a.drucker(drucker.port);
      expect((await drucke(id)).ok, isTrue);
      await warteAufStatusfaehig(a, id);
      drucker.dleEot.clear();
      expect((await drucke(id, jobId: 'beleg-2')).code, errorPrinterNotReady);
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
      final id = await a.drucker(drucker.port, statusCapableAt: seit);
      await drucker.stop();
      final ergebnis = await a.queue.enqueue(id, 'beleg-1', beispielBon);
      expect(ergebnis.code, errorPrinterOffline);
      drucker = await FakeTcpPrinter.start(dleEot: _gesund);
    });
  });

  group('Statustakt', () {
    test(
      'statusfähig und stumm: readiness not_ready, nie „stumm“ gemerkt',
      () async {
        final id = await a.drucker(drucker.port, statusCapableAt: seit);
        final dienst = DruckerStatusDienst(
          registry: a.registry,
          queue: a.queue,
          abfrage: EscPosAbfrage(),
          kasseZuletzt: () => a.jetzt,
          clock: () => a.jetzt,
        );
        drucker.dleEot.clear();
        await dienst.runde();
        var eintrag = (await a.registry.summaries()).single;
        expect(eintrag['readiness'], 'not_ready');
        expect(eintrag['state'], 'online');
        expect(a.registry.lagen.von(id).stumm(a.jetzt), isFalse);

        drucker.dleEot.addAll(_gesund);
        await dienst.runde();
        eintrag = (await a.registry.summaries()).single;
        expect(eintrag['readiness'], 'ready');
      },
    );

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
      expect((await a.store.load()).printers.single.statusCapableAt, isNotNull);
      expect(id, isNotEmpty);
    });
  });
}

/// Spielraum für Planung und Verbindungsaufbau im Test.
const Duration _spiel = Duration(milliseconds: 300);

Future<void> warteAufStatusfaehig(DruckAufbau a, String id) async {
  final ende = DateTime.now().add(const Duration(seconds: 5));
  while ((await a.store.load()).printers
          .singleWhere((d) => d.id == id)
          .statusCapableAt ==
      null) {
    if (DateTime.now().isAfter(ende)) fail('$id wurde nicht statusfähig');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
