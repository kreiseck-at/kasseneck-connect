import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';
import 'support/virtuelles_netz.dart';

const Map<int, int> _gesund = <int, int>{1: 0x16, 2: 0x12, 3: 0x12, 4: 0x12};
const String _mac = '00:26:ab:00:00:01';
const String _serie = 'X5ZT000123';

/// Ein langer Bon (Tagesabschluss): 8 KB Text.
final Uint8List _langerBon = Uint8List.fromList(<int>[
  0x1B, 0x40, //
  ...List<int>.filled(8000, 0x41),
  0x0A, 0x1D, 0x56, 0x01,
]);

/// Was rund um einen Bon geschieht: ein Drucker, der noch druckt, ist nicht
/// „nicht bereit“; einer, der die vorige Verbindung noch hält, ist nicht
/// umgezogen; einer, der aus ist, kostet nicht länger als bis 1.4.2.
void main() {
  group('Schweigen kurz nach dem eigenen Bon', () {
    late DruckAufbau a;
    late FakeTcpPrinter drucker;
    final seit = DateTime.utc(2026, 11, 1, 9);

    setUp(() async {
      drucker = await FakeTcpPrinter.start(dleEot: _gesund);
      a = DruckAufbau.erstellen(verbinden: drucker.verbinden);
      a.arpMac = _mac;
    });

    tearDown(() async {
      await a.aufraeumen();
      await drucker.stop();
    });

    Future<PrintResult> drucke(String id, {Uint8List? bytes}) async {
      final vorher = drucker.druckVerbindungen.length;
      final ergebnis = await a.drucke(id, bytes: bytes);
      if (ergebnis.ok) await drucker.warteAufDruck(vorher);
      return ergebnis;
    }

    test('der Drucker schweigt, solange er druckt: der nächste Bon geht wie '
        'bis 1.4.2, nicht printer_not_ready', () async {
      // Die Uhr der Vorprüfung steht: der lange Bon „druckt“ für sie noch.
      drucker.druckDauer = const Duration(seconds: 5);
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      expect((await drucke(id, bytes: _langerBon)).ok, isTrue);
      final zweiter = await drucke(id);
      expect(zweiter.ok, isTrue, reason: '${zweiter.code}');
      expect(drucker.druckVerbindungen, hasLength(2));
      expect((await a.registry.summaries()).single['readiness'], 'unknown');
    });

    test('nach dem Nachlauf zählt Schweigen wieder – „nicht bereit“ erst nach '
        '30 s am Stück', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      expect((await drucke(id, bytes: _langerBon)).ok, isTrue);
      drucker.dleEot.clear(); // Deckel auf
      a.jetzt = a.jetzt.add(druckNachlauf(_langerBon.length));
      expect((await drucke(id)).ok, isTrue, reason: 'erstes Schweigen');
      a.jetzt = a.jetzt
          .add(druckNachlauf(beispielBon.length))
          .add(schweigenMindestdauer);
      expect((await a.drucke(id)).code, errorPrinterNotReady);
    });

    test('der Nachlauf wächst mit dem Bon und ist mindestens 3 s', () {
      expect(druckNachlauf(0), druckNachlaufMindestens);
      expect(druckNachlaufMindestens, const Duration(seconds: 3));
      // 25 KB Tagesabschluss: großzügig mehr als eine halbe Minute.
      expect(druckNachlauf(25000), greaterThan(const Duration(seconds: 25)));
    });

    test('ein Gerät, das kurz nach dem Bon schweigt, gilt nicht für zehn '
        'Minuten als stumm', () async {
      drucker.dleEot.clear();
      final id = await a.drucker(drucker.port);
      a.registry.lagen.von(id).druckGesendet(_langerBon.length, a.jetzt);
      expect((await drucke(id)).ok, isTrue);
      expect(a.registry.lagen.von(id).stumm(a.jetzt), isFalse);
      // Ohne eigenen Bon davor schon.
      a.jetzt = a.jetzt.add(druckNachlauf(_langerBon.length));
      expect((await drucke(id)).ok, isTrue);
      expect(a.registry.lagen.von(id).stumm(a.jetzt), isTrue);
    });

    test('der Statustakt fragt nicht, solange der eigene Bon druckt; danach '
        'schon', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      final dienst = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(verbinden: drucker.verbinden),
        kasseZuletzt: () => a.jetzt,
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
      );
      expect((await drucke(id, bytes: _langerBon)).ok, isTrue);
      await drucker.ruhigNachVerbindung();
      final vorher = drucker.connections;
      await dienst.runde();
      expect(drucker.connections, vorher, reason: 'keine Abfrage');
      expect(a.registry.lagen.von(id).verfehltInFolge, 0);

      a.jetzt = a.jetzt.add(druckNachlauf(_langerBon.length));
      await dienst.runde();
      expect(drucker.connections, vorher + 1);
      expect((await a.registry.summaries()).single['readiness'], 'ready');
      expect(id, isNotEmpty);
    });

    test(
      'Abfrage auf Zuruf direkt nach dem Bon: Schweigen ist unbekannt',
      () async {
        final id = await a.drucker(
          drucker.port,
          statusCapableAt: seit,
          mac: _mac,
        );
        final dienst = DruckerStatusDienst(
          registry: a.registry,
          queue: a.queue,
          abfrage: EscPosAbfrage(verbinden: drucker.verbinden),
          kasseZuletzt: () => a.jetzt,
          arp: a.arp,
          schnittstellen: () async => a.schnittstellen,
          clock: () => a.jetzt,
        );
        expect((await drucke(id, bytes: _langerBon)).ok, isTrue);
        drucker.dleEot.clear();
        final eintrag = await dienst.jetzt(id);
        expect(eintrag!['readiness'], 'unknown');
      },
    );
  });

  group('Drucker gibt seine Verbindung langsam frei', () {
    late DruckAufbau a;
    late FakeTcpPrinter drucker;

    setUp(() async {
      // Nimmt nur eine Verbindung zugleich an und gibt die vorige erst
      // 800 ms nach dem Schließen frei.
      drucker = await FakeTcpPrinter.start(dleEot: _gesund)
        ..eineVerbindung = true
        ..freigabeVerzug = const Duration(milliseconds: 800);
      a = DruckAufbau.erstellen(verbinden: drucker.verbinden);
    });

    tearDown(() async {
      await a.aufraeumen();
      await drucker.stop();
    });

    test(
      'Druckverbindung nach der Abfrage abgelehnt: dieselbe Adresse in '
      'kurzen Schritten, ohne Suche; danach keine Abfrage mehr vor dem Bon',
      () async {
        final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
        drucker.gsI[68] = _serie;
        final ergebnis = await a.drucke(id);
        expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
        await drucker.warteAufDruck(0);
        expect(drucker.abgelehnt, greaterThanOrEqualTo(1));
        expect(drucker.druckVerbindungen.single, beispielBon);
        expect(a.wiederfinder.suchen, 0);
        expect(a.registry.lagen.von(id).gibtLangsamFrei, isTrue);
        expect(drucker.freigabeVerzug, lessThan(freigabeFenster));

        // Der nächste Bon nach der Freigabe: wie 1.4.2, keine Abfrage.
        final abfragen = drucker.abfrageVerbindungen.length;
        await Future<void>.delayed(drucker.freigabeVerzug * 1.5);
        expect((await a.drucke(id)).ok, isTrue);
        await drucker.warteAufDruck(1);
        expect(drucker.abfrageVerbindungen, hasLength(abfragen));
      },
    );

    test(
      'vier Bons im Abstand der Kasse: alle gedruckt (1.4.2: 4/4)',
      () async {
        // Probe der Nachprüfung: 1.5.0 druckte hier 0 von 4.
        final id = await a.drucker(
          drucker.port,
          statusCapableAt: DateTime.utc(2026, 11, 1),
        );
        for (var i = 0; i < 4; i++) {
          expect((await a.drucke(id)).ok, isTrue, reason: 'Bon ${i + 1}');
          a.jetzt = a.jetzt.add(const Duration(minutes: 1));
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
        expect(drucker.druckVerbindungen, hasLength(4));
      },
    );

    test('Takt, direkt danach ein Bon: die abgelehnte Abfrage heißt „gibt '
        'langsam frei“, nicht „aus“ – der Bon geht', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: DateTime.utc(2026, 11, 1),
      );
      final dienst = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(verbinden: drucker.verbinden),
        kasseZuletzt: () => a.jetzt,
        clock: () => a.jetzt,
      );
      await dienst.runde();
      expect(drucker.abfrageVerbindungen, hasLength(1));
      final ergebnis = await a.drucke(id);
      expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
      expect(a.registry.lagen.von(id).gibtLangsamFrei, isTrue);
      await drucker.warteAufDruck(0);
      // Ab jetzt auch kein Takt mehr.
      final verbindungen = drucker.connections;
      await Future<void>.delayed(drucker.freigabeVerzug * 1.5);
      await dienst.runde();
      expect(drucker.connections, verbindungen);
    });

    test('der Fake hält immer nur eine Verbindung', () async {
      final id = await a.drucker(drucker.port, serial: _serie, mac: _mac);
      drucker.gsI[68] = _serie;
      for (var i = 0; i < 3; i++) {
        expect((await a.drucke(id)).ok, isTrue);
        await Future<void>.delayed(drucker.freigabeVerzug * 1.5);
      }
      expect(drucker.hoechstAngenommen, 1);
    });
  });

  group('nicht bewiesenes Modell: Druckpfad wie 1.4.2', () {
    test('keine Abfrage-Verbindung, kein ARP, nur die Bytes der Kasse – '
        'Verbindungsfolge wie mit allen Neuerungen aus', () async {
      Future<List<List<int>>> ablauf({required bool alleAus}) async {
        final drucker = await FakeTcpPrinter.start(
          dleEot: _gesund,
          gsI: const <int, String>{67: 'TM-T88VI', 68: _serie},
        );
        final a = DruckAufbau.erstellen(verbinden: drucker.verbinden)
          ..arpMac = _mac;
        if (alleAus) await a.abschalten(Neuerung.values);
        final id = await a.drucker(
          drucker.port,
          model: 'TM-T88VI',
          serial: _serie,
          mac: _mac,
          statusCapableAt: DateTime.utc(2026, 11, 1),
        );
        for (var i = 0; i < 3; i++) {
          expect((await a.drucke(id)).ok, isTrue);
          await drucker.warteAufDruck(i);
        }
        final arp = a.arpAufrufe;
        await a.aufraeumen();
        await drucker.stop();
        expect(arp, 0, reason: 'kein ARP vor dem Bon');
        return drucker.verbindungen.map((v) => v.bytes).toList();
      }

      final neu = await ablauf(alleAus: false);
      final alt = await ablauf(alleAus: true);
      expect(neu, alt);
      expect(neu, <List<int>>[beispielBon, beispielBon, beispielBon]);
    });

    test('ohne Modell (nie erkannt): ebenso', () async {
      final drucker = await FakeTcpPrinter.start(dleEot: _gesund);
      final a = DruckAufbau.erstellen(verbinden: drucker.verbinden);
      addTearDown(() async {
        await a.aufraeumen();
        await drucker.stop();
      });
      final id = await a.drucker(drucker.port, model: null, serial: _serie);
      expect((await a.drucke(id)).ok, isTrue);
      await drucker.warteAufDruck(0);
      expect(drucker.verbindungen.map((v) => v.bytes), <List<int>>[
        beispielBon,
      ]);
    });

    test('ein Modell aus mDNS zählt nicht (nur GS I 67)', () {
      final drucker = PrinterConfig(
        id: 'p1',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
        model: bewiesenesTestModell,
        modelSource: KennungsQuelle.mdns,
      );
      expect(modellBewiesen(drucker, liste: testModelle), isFalse);
      expect(
        modellBewiesen(
          drucker.copyWith(modelSource: KennungsQuelle.escpos),
          liste: testModelle,
        ),
        isTrue,
      );
      // Die Liste des Betriebs ist bis zum Gerätetest leer.
      expect(bewieseneModelle, isEmpty);
      expect(
        modellBewiesen(drucker.copyWith(modelSource: KennungsQuelle.escpos)),
        isFalse,
      );
    });
  });

  group('ausgeschalteter Drucker: nie länger als bis 1.4.2', () {
    const aus = '192.168.0.50';

    /// Verbindungsaufbau, der wie bei einem ausgeschalteten Gerät in die
    /// Zeitgrenze läuft – ohne zu warten; die Zeitgrenzen werden gezählt.
    late List<Duration> zeitgrenzen;
    late DruckAufbau a;

    Future<Socket> zeitueberschreitung(
      String host,
      int port, {
      Duration? timeout,
    }) {
      zeitgrenzen.add(timeout ?? defaultConnectTimeout);
      return Future<Socket>.error(
        const SocketException('Connection timed out'),
      );
    }

    setUp(() {
      zeitgrenzen = <Duration>[];
      // Das virtuelle Netz liefert die ARP-Tabelle (veralteter Eintrag);
      // jede Verbindung läuft in die Zeitgrenze. Zeitgrenzen des Betriebs.
      final netz = VirtuellesNetz()..macs[aus] = _mac;
      a = DruckAufbau.erstellen(
        netz: netz,
        verbinden: zeitueberschreitung,
        budget: vorpruefungBudget,
        budgetStatusfaehig: vorpruefungBudgetStatusfaehig,
        aufbauGrenze: langsamerAufbau,
      );
    });

    tearDown(() => a.aufraeumen());

    Duration summe(Iterable<Duration> d) =>
        d.fold(Duration.zero, (x, y) => x + y);

    test('die Abfrage ohne Verbindung zählt als erster Versuch: '
        'Zeitgrenzen zusammen höchstens die zweier Druckversuche', () async {
      final id = await a.drucker(
        9100,
        host: aus,
        serial: _serie,
        mac: _mac,
        statusCapableAt: DateTime.utc(2026, 11, 1),
      );
      final ergebnis = await a.drucke(id);
      expect(ergebnis.code, errorPrinterOffline);
      // Abfrage plus ein Druckversuch.
      expect(zeitgrenzen, hasLength(2));
      expect(zeitgrenzen.last, defaultConnectTimeout);
      expect(
        summe(zeitgrenzen) + schnellesWiederfindenBudget,
        lessThanOrEqualTo(
          defaultConnectTimeout * 2 + const Duration(seconds: 1),
        ),
      );
      // Mit MAC nur ARP: kein mDNS, keine weitere Verbindung.
      expect(a.wiederfinder.schnelleSuchen, 1);
    });

    test('zwei Aufträge hintereinander (zwei Kassen): das schnelle '
        'Wiederfinden läuft einmal, beide zusammen unter 1.4.2', () async {
      final id = await a.drucker(
        9100,
        host: aus,
        serial: _serie,
        mac: _mac,
        statusCapableAt: DateTime.utc(2026, 11, 1),
      );
      final beide = await Future.wait(<Future<PrintResult>>[
        a.queue.enqueue(id, 'beleg-1', beispielBon),
        a.queue.enqueue(id, 'beleg-2', beispielBon),
      ]);
      expect(beide.map((r) => r.code), <String?>[
        errorPrinterOffline,
        errorPrinterOffline,
      ]);
      expect(zeitgrenzen, hasLength(4));
      expect(summe(zeitgrenzen), lessThan(defaultConnectTimeout * 4));
      expect(a.wiederfinder.schnelleSuchen, 1);
    });

    test('wie 1.4.2 (alle Neuerungen aus): zwei Druckversuche', () async {
      await a.abschalten(Neuerung.values);
      final id = await a.drucker(9100, host: aus, serial: _serie, mac: _mac);
      expect((await a.drucke(id)).code, errorPrinterOffline);
      expect(zeitgrenzen, <Duration>[
        defaultConnectTimeout,
        defaultConnectTimeout,
      ]);
    });
  });
}
