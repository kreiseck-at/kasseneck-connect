import 'dart:async';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';

const String _mac = '00:26:ab:00:00:01';
const String _serie = 'X5ZT000123';

/// Zwei Rechner (A und B) an einem Drucker, der nur eine Verbindung zugleich
/// annimmt. A fragt nach, weil der Drucker schweigt (er druckt gerade einen
/// fremden Bon); genau dann druckt B. 1.4.2 hätte den Bon von B gedruckt –
/// die Nachfrage von A darf ihn nicht verhindern.
void main() {
  late FakeTcpPrinter drucker;
  late DruckAufbau a;
  late DruckAufbau b;
  late DruckerStatusDienst dienstA;
  final seit = DateTime.utc(2026, 11, 1);

  setUp(() async {
    // Schweigt auf DLE EOT (druckt fremd): eine Nachfrage hält die
    // Verbindung das volle Antwortfenster.
    drucker = await FakeTcpPrinter.start()
      ..eineVerbindung = true;
    a = DruckAufbau.erstellen(verbinden: drucker.verbinden);
    b = DruckAufbau.erstellen(verbinden: drucker.verbinden);
    for (final x in <DruckAufbau>[a, b]) {
      x.arpMac = _mac;
      await x.drucker(
        drucker.port,
        statusCapableAt: seit,
        mac: _mac,
        serial: _serie,
      );
    }
    dienstA = DruckerStatusDienst(
      registry: a.registry,
      queue: a.queue,
      abfrage: EscPosAbfrage(verbinden: drucker.verbinden),
      kasseZuletzt: () => a.jetzt,
      arp: a.arp,
      schnittstellen: () async => a.schnittstellen,
      clock: () => a.jetzt,
    );
  });

  tearDown(() async {
    await a.aufraeumen();
    await b.aufraeumen();
    await drucker.stop();
  });

  /// A fragt nach (500 ms Antwortfenster, der Drucker schweigt) – liefert,
  /// sobald die Verbindung von A steht.
  Future<Future<bool>> nachfrageVonA(String id) async {
    a.registry.lagen.von(id).schweigt(a.jetzt);
    final vorher = drucker.connections;
    final lauf = dienstA.nachfrage(id);
    await warteBis(
      () async => drucker.connections > vorher,
      grund: 'Verbindung von A',
    );
    return lauf;
  }

  test('Sollte 1b: B ohne Kontakt, Abfrage abgelehnt (ohneVerbindung): der '
      'zweite Druckversuch nach der Pause druckt', () async {
    const id = 'p_ab12cd34';
    final a1 = await nachfrageVonA(id);
    final ergebnis = await b.drucke(id);
    expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
    await a1;
    await drucker.warteAufDruck(0);
    expect(drucker.druckVerbindungen.single, beispielBon);
    expect(drucker.abgelehnt, greaterThanOrEqualTo(2));
  });

  test('Sollte 1a: B war eben verbunden, Abfrage abgelehnt: „belegt“ – die '
      'Freigabe-Schleife druckt, ohne Suche und ohne „gibt langsam '
      'frei“', () async {
    const id = 'p_ab12cd34';
    // B hatte vor gut 3 s eine eigene Verbindung (Bon, Takt): älter als das
    // Freigabefenster, jünger als das Kontaktfenster.
    b.registry.lagen.von(id).verbunden();
    await Future<void>.delayed(
      freigabeFenster + const Duration(milliseconds: 200),
    );
    expect(b.registry.lagen.von(id).ebenVerbunden(), isFalse);
    expect(b.registry.lagen.von(id).kuerzlichVerbunden(), isTrue);
    final a1 = await nachfrageVonA(id);
    final ergebnis = await b.drucke(id);
    expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
    await a1;
    await drucker.warteAufDruck(0);
    expect(b.wiederfinder.schnelleSuchen, 0, reason: 'keine Suche');
    expect(b.registry.lagen.von(id).gibtLangsamFrei, isFalse);
    expect(b.registry.pruefbar((await b.store.load()).printers.single), isTrue);
  });

  test('Sollte 1: B druckt ohne Abfrage (eigener Bon druckt noch), die '
      'Druckverbindung wird abgelehnt: der zweite Versuch wartet die '
      'Abfrage von A ab', () async {
    const id = 'p_ab12cd34';
    // Der vorige Bon von B druckt nach seiner Uhr noch: keine Abfrage.
    b.registry.lagen.von(id).druckGesendet(8000, b.jetzt);
    final a1 = await nachfrageVonA(id);
    final ergebnis = await b.drucke(id);
    expect(ergebnis.ok, isTrue, reason: '${ergebnis.code}');
    await a1;
    await drucker.warteAufDruck(0);
    expect(drucker.abfrageVerbindungen, hasLength(1), reason: 'nur A');
  });

  test('ein nicht bewiesenes Modell wiederholt sofort wie bis 1.4.2', () async {
    await b.drucker(drucker.port, model: null);
    const id = 'p_ab12cd34';
    final a1 = await nachfrageVonA(id);
    final uhr = Stopwatch()..start();
    final ergebnis = await b.drucke(id);
    uhr.stop();
    // A fragt nur bewiesene Modelle ab; hier hält die Verbindung der Test.
    expect(ergebnis.code, errorPrinterOffline);
    expect(uhr.elapsed, lessThan(zweiterVersuchPause));
    await a1;
  });
}
