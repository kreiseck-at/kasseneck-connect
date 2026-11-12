import 'dart:async';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';
import 'support/virtuelles_netz.dart';

/// Gerätetest TM-T20III (10.11.2026): mit offenem Deckel oder ohne Papier
/// nimmt der Drucker die Verbindung an und beantwortet `DLE EOT` gar nicht –
/// keine Statusbits, nur Schweigen. Gerätetest 12.11.2026: genauso schweigt
/// er, solange er einen anderen Rechner bedient. Schweigen ist deshalb nur
/// ein Hinweis (`readinessHint: no_status_answer`), nie „nicht bereit“ und
/// nie ein Grund, einen Bon aufzuhalten.
///
/// Rot-Probe: „statusfähig und stumm …: nie printer_not_ready“ lieferte auf
/// dem Stand vorher `printer_not_ready` (nach 30 s Schweigen).
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

  /// Statusdienst wie im Agenten, mit der Uhr des Tests.
  DruckerStatusDienst dienst({Duration? nachfrageAbstand}) =>
      DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(aufbauGrenze: testAufbauGrenze),
        kasseZuletzt: () => a.jetzt,
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
        budget: testBudgetStatusfaehig,
        abstand: const Duration(hours: 1),
        nachfrageAbstand: nachfrageAbstand ?? schweigenNachfrageAbstand,
        // Kürzeres Antwortfenster: der Fake antwortet sofort oder nie.
        nachfrageFrist: const Duration(milliseconds: 150),
      );

  Future<PrintResult> drucke(String id, {String jobId = 'beleg-1'}) async {
    final vorher = drucker.druckVerbindungen.length;
    final ergebnis = await a.queue.enqueue(id, jobId, beispielBon);
    if (ergebnis.ok) await drucker.warteAufDruck(vorher);
    return ergebnis;
  }

  /// Der eigene Bon ist längst gedruckt: die nächste Prüfung fragt wieder.
  void spaeter() => a.jetzt = a.jetzt.add(const Duration(minutes: 1));

  Future<Map<String, Object?>> eintrag() async =>
      (await a.registry.summaries()).single;

  group('Deutung', () {
    test('Folge ohne Antwort: eine ändert nichts, ab der zweiten unbekannt mit '
        'Hinweis, eine Antwort beendet sie; andere MAC: ohne Hinweis', () {
      final lage = DruckerLage();
      expect(zustandOhneAntwort(lage, MacVergleich.gleich), isNull);
      lage.ohneAntwort();
      expect(zustandOhneAntwort(lage, MacVergleich.gleich), isNull);
      lage.ohneAntwort();
      expect(
        zustandOhneAntwort(lage, MacVergleich.gleich),
        DruckerZustand.keineAntwort,
      );
      expect(
        zustandOhneAntwort(lage, MacVergleich.unbekannt),
        DruckerZustand.keineAntwort,
      );
      expect(
        zustandOhneAntwort(lage, MacVergleich.anders),
        DruckerZustand.unbekannt,
      );
      expect(DruckerZustand.keineAntwort.sperre, isNull, reason: 'nie Sperre');
      lage.antwortet();
      expect(lage.ohneAntwortInFolge, 0);
      expect(zustandOhneAntwort(lage, MacVergleich.gleich), isNull);
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
    test('statusfähig, gleiche MAC, schweigt (Deckel offen) auch nach 30 s am '
        'Stück: nie printer_not_ready, der Bon geht wie bis 1.4.2; ab der '
        'zweiten stummen Abfrage der Hinweis', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      expect((await drucke(id)).ok, isTrue);
      expect((await eintrag())['readiness'], 'ready');
      drucker.dleEot.clear(); // Deckel auf
      // Bon um Bon, gut 30 s lang (der eigene vorige ist jeweils durch).
      for (var i = 0; i < 8; i++) {
        a.jetzt = a.jetzt.add(druckNachlauf(beispielBon.length));
        final ergebnis = await drucke(id, jobId: 'beleg-${i + 2}');
        expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
        final jetzt = await eintrag();
        if (i == 0) {
          expect(jetzt['readiness'], 'ready', reason: 'eine ändert nichts');
          expect(jetzt.containsKey('readinessHint'), isFalse);
        } else {
          expect(jetzt['readiness'], 'unknown');
          expect(jetzt['readinessHint'], 'no_status_answer');
          expect(jetzt['state'], 'online', reason: 'erreichbar');
        }
      }
      // Jeder Bon ging hinaus, Byte für Byte; je Bon ein Versuch.
      expect(drucker.druckVerbindungen, hasLength(9));
      expect(
        drucker.druckVerbindungen.every((b) => _gleich(b, beispielBon)),
        isTrue,
      );

      // Deckel zu: die nächste Antwort beendet den Hinweis.
      drucker.dleEot.addAll(_gesund);
      spaeter();
      expect((await drucke(id, jobId: 'beleg-zu')).ok, isTrue);
      final zu = await eintrag();
      expect(zu['readiness'], 'ready');
      expect(zu.containsKey('readinessHint'), isFalse);
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
      // Ab jetzt zählt sein Schweigen – als Hinweis.
      drucker.dleEot.clear();
      final lage = a.registry.lagen.von(id);
      spaeter();
      // Die Konfiguration im Speicher der Prüfung ist frisch geladen.
      expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
      expect(lage.ohneAntwortInFolge, 1);
      expect(lage.stumm(a.jetzt), isFalse, reason: 'nie als stumm gemerkt');
    });

    test('eine gültige Antwort beendet die Folge', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      final lage = a.registry.lagen.von(id)
        ..ohneAntwort()
        ..ohneAntwort();
      expect((await drucke(id)).ok, isTrue, reason: 'antwortet');
      expect(lage.ohneAntwortInFolge, 0);
      expect((await eintrag())['readiness'], 'ready');
      spaeter();
      drucker.dleEot.clear();
      expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
      expect((await eintrag())['readiness'], 'ready', reason: 'erst eine');
    });

    test(
      'statusfähig und stumm, Kennung nicht bestätigt (keine MAC, keine '
      'frische Seriennummer): Druck wie 1.4.2, Hinweis erst ab der zweiten',
      () async {
        final id = await a.drucker(drucker.port, statusCapableAt: seit);
        drucker.dleEot.clear();
        expect((await drucke(id)).ok, isTrue);
        expect(drucker.druckVerbindungen.single, beispielBon);
        spaeter();
        expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
        expect((await eintrag())['readinessHint'], 'no_status_answer');
      },
    );

    test('frisch bestätigt, jetzt aber eine andere MAC und stumm: wie 1.4.2, '
        'unbekannt ohne Hinweis', () async {
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
      for (var i = 2; i <= 3; i++) {
        spaeter();
        expect((await drucke(id, jobId: 'beleg-$i')).ok, isTrue);
      }
      final jetzt = await eintrag();
      expect(jetzt['readiness'], 'unknown');
      expect(jetzt.containsKey('readinessHint'), isFalse);
    });

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

    test('stumm und eine andere MAC unter der Adresse: wie 1.4.2', () async {
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

    test('nimmt keine Verbindung an: printer_offline wie 1.4.2', () async {
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
    test('statusfähig und stumm: die erste Runde ändert nichts, ab der '
        'zweiten unbekannt mit Hinweis, nie not_ready, nie „stumm“ gemerkt; '
        'die nächste Antwort: ready', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      final d = dienst();
      await d.runde();
      expect((await eintrag())['readiness'], 'ready');
      drucker.dleEot.clear();
      for (var i = 0; i < 8; i++) {
        a.jetzt = a.jetzt.add(schweigenNachfrageAbstand);
        await d.runde();
        final jetzt = await eintrag();
        expect(jetzt['readiness'], i == 0 ? 'ready' : 'unknown');
        expect(jetzt['readinessHint'], i == 0 ? isNull : 'no_status_answer');
        expect(jetzt['state'], 'online');
      }
      expect(a.registry.lagen.von(id).stumm(a.jetzt), isFalse);

      drucker.dleEot.addAll(_gesund);
      a.jetzt = a.jetzt.add(schweigenNachfrageAbstand);
      await d.runde();
      final zu = await eintrag();
      expect(zu['readiness'], 'ready');
      expect(zu.containsKey('readinessHint'), isFalse);
    });

    test('Nachfragen laufen von selbst, solange er schweigt (nur bei '
        'laufendem Dienst), einzeln über die Warteschlange, und enden mit der '
        'ersten Antwort', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      final d = dienst(nachfrageAbstand: const Duration(milliseconds: 30));
      drucker.dleEot.clear();
      // Ohne start(): keine Nachfrage.
      await d.runde();
      expect(d.verfolgt(id), isFalse);

      d.start();
      addTearDown(d.stop);
      await d.runde();
      expect(d.verfolgt(id), isTrue);
      await warteBis(() async => d.nachfragen >= 2, grund: 'Nachfragen');
      expect(drucker.hoechstAngenommen, 1, reason: 'nie zwei zugleich');
      drucker.dleEot.addAll(_gesund);
      await warteBis(
        () async => !d.verfolgt(id),
        grund: 'Ende nach der Antwort',
      );
      final danach = d.nachfragen;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(d.nachfragen, danach, reason: 'keine weitere Nachfrage');
      expect((await a.registry.summaries()).single['readiness'], 'ready');
    });

    test('Sollte 2: unter der Adresse eine andere MAC – keine Nachfrage, '
        'weder aus dem Takt noch vor dem Bon', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = '00:26:ab:00:00:09'; // ein anderes Gerät
      final d = dienst(nachfrageAbstand: const Duration(milliseconds: 30));
      d.start();
      addTearDown(d.stop);
      drucker.dleEot.clear();
      await d.runde();
      expect(d.verfolgt(id), isFalse, reason: 'Takt');
      final verbindungen = drucker.connections;
      expect(await d.nachfrage(id), isFalse);
      expect(drucker.connections, verbindungen, reason: 'kein Byte');

      final angestossen = <String>[];
      a.vorpruefung.beiSchweigen = angestossen.add;
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      expect((await drucke(id)).ok, isTrue);
      expect(angestossen, isEmpty, reason: 'vor dem Bon');

      // Gegenprobe: dieselbe MAC – vor dem Bon angestoßen.
      a.arpMac = _mac;
      a.jetzt = a.jetzt.add(const Duration(minutes: 1));
      expect((await drucke(id, jobId: 'beleg-2')).ok, isTrue);
      expect(angestossen, <String>[id]);
    });

    test(
      'nach stop() keine Nachfrage mehr – auch keine schon geplante',
      () async {
        final id = await a.drucker(
          drucker.port,
          statusCapableAt: seit,
          mac: _mac,
        );
        a.arpMac = _mac;
        final d = dienst(nachfrageAbstand: const Duration(milliseconds: 150));
        d.start();
        drucker.dleEot.clear();
        await d.runde();
        expect(d.verfolgt(id), isTrue, reason: 'Nachfrage geplant');
        final verbindungen = drucker.connections;
        await d.stop();
        expect(d.verfolgt(id), isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(d.nachfragen, 0);
        expect(drucker.connections, verbindungen);
        // Auch ein neuer Anstoß plant nach dem Anhalten nichts.
        d.schweigenVerfolgen(id);
        expect(d.verfolgt(id), isFalse);
      },
    );

    test('keine Nachfrage: Kasse zu, status_poll oder printer_status aus, '
        'nicht bewiesenes Modell, eigener Bon druckt noch', () async {
      final id = await a.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
      );
      a.arpMac = _mac;
      var kasse = a.jetzt;
      final d = DruckerStatusDienst(
        registry: a.registry,
        queue: a.queue,
        abfrage: EscPosAbfrage(aufbauGrenze: testAufbauGrenze),
        kasseZuletzt: () => kasse,
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
        budget: testBudgetStatusfaehig,
      );
      drucker.dleEot.clear();
      await d.runde();
      final verbindungen = drucker.connections;

      // Eigener Bon druckt: keine Abfrage, aber weiter verfolgen.
      a.registry.lagen.von(id).druckGesendet(8000, a.jetzt);
      expect(await d.nachfrage(id), isTrue);
      expect(drucker.connections, verbindungen);
      a.jetzt = a.jetzt.add(druckNachlauf(8000));

      kasse = a.jetzt.subtract(const Duration(minutes: 3));
      expect(await d.nachfrage(id), isFalse, reason: 'Kasse zu');
      kasse = a.jetzt;
      await a.abschalten(<Neuerung>[Neuerung.statusTakt]);
      expect(await d.nachfrage(id), isFalse, reason: 'status_poll aus');
      await a.abschalten(<Neuerung>[Neuerung.druckerStatus]);
      expect(await d.nachfrage(id), isFalse, reason: 'printer_status aus');
      await a.abschalten(const <Neuerung>[]);
      await a.drucker(drucker.port, statusCapableAt: seit, model: 'TM-T88VI');
      expect(await d.nachfrage(id), isFalse, reason: 'nicht bewiesen');
      expect(drucker.connections, verbindungen);
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

bool _gleich(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
