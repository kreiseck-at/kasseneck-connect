import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';

const Map<int, int> _gesund = <int, int>{2: 0x12, 4: 0x12};

/// `GS I n` als Bytes.
List<int> _gsI(int n) => <int>[0x1D, 0x49, n];

/// Ob [bytes] die Folge [folge] enthalten.
bool _enthaelt(List<int> bytes, List<int> folge) {
  for (var i = 0; i + folge.length <= bytes.length; i++) {
    var gleich = true;
    for (var j = 0; j < folge.length; j++) {
      if (bytes[i + j] != folge[j]) {
        gleich = false;
        break;
      }
    }
    if (gleich) return true;
  }
  return false;
}

/// Ein ESC/POS-Nachbau, der `DLE EOT` versteht, `GS I` aber nicht: er
/// könnte die Zeichen eines `GS I` als Text puffern, die dann auf dem
/// nächsten Bon stünden. `GS I` bekommt er deshalb höchstens einmal je
/// Einrichtung – und nach einem unbeantworteten `GS I 67` kein `GS I 68`.
void main() {
  late DruckAufbau a;
  late FakeTcpPrinter nachbau;
  late Kennungspflege pflege;

  setUp(() async {
    nachbau = await FakeTcpPrinter.start(dleEot: _gesund);
    a = DruckAufbau.erstellen(verbinden: nachbau.verbinden);
    pflege = Kennungspflege(
      store: a.store,
      queue: a.queue,
      lagen: a.registry.lagen,
      log: a.log,
      clock: () => a.jetzt,
      erkennung: DruckerErkennung(
        abfrage: EscPosAbfrage(
          verbinden: nachbau.verbinden,
          aufbauGrenze: testAufbauGrenze,
        ),
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
        // Volle Frist für GS I (gsIVolleFrist), der Nachbau antwortet nie.
        budget: const Duration(milliseconds: 1300),
      ),
    );
  });

  tearDown(() async {
    await pflege.erledigt();
    await a.aufraeumen();
    await nachbau.stop();
  });

  Future<PrinterConfig> gespeichert() async =>
      (await a.store.load()).printers.single;

  test('Sollte 3: ein Schweigen mit voller Frist ist nur vorgemerkt; binnen '
      '6 h kein GS I, danach ein zweites; erst das zweite gilt dauerhaft – '
      'auch über eine Umbenennung, nicht über eine neue Adresse', () async {
    final id = await a.drucker(nachbau.port, model: null);
    await pflege.nachAnlegen(id);
    var bytes = nachbau.received.toList();
    expect(_enthaelt(bytes, _gsI(67)), isTrue, reason: 'beim Anlegen');
    expect(_enthaelt(bytes, _gsI(68)), isFalse, reason: 'nach stummem 67');
    var nach = await gespeichert();
    expect(nach.idQueryMissedAt, isNotNull, reason: 'vorgemerkt');
    expect(nach.idQueryUnansweredAt, isNull, reason: 'erst beim zweiten Mal');
    expect(nach.statusCapableAt, isNotNull, reason: 'DLE EOT beantwortet');

    // Auf Zuruf binnen 6 h: nur DLE EOT.
    a.jetzt = a.jetzt.add(erkennungsAbstand);
    var vorher = nachbau.received.length;
    await pflege.aufZuruf(id);
    bytes = nachbau.received.sublist(vorher);
    expect(bytes, isNotEmpty, reason: 'DLE EOT ging hinaus');
    expect(_enthaelt(bytes, const <int>[0x1D, 0x49]), isFalse);

    // 6 h nach dem ersten Mal: ein zweites GS I 67 – wieder ohne Antwort.
    a.jetzt = a.jetzt.add(gsIZweiterVersuchFruehestens);
    vorher = nachbau.received.length;
    await pflege.aufZuruf(id);
    expect(_enthaelt(nachbau.received.sublist(vorher), _gsI(67)), isTrue);
    nach = await gespeichert();
    expect(nach.idQueryUnansweredAt, isNotNull, reason: 'jetzt dauerhaft');

    // Danach nie mehr: weder auf Zuruf noch nach der Suche …
    a.jetzt = a.jetzt.add(const Duration(days: 1));
    vorher = nachbau.received.length;
    await pflege.aufZuruf(id);
    a.jetzt = a.jetzt.add(erkennungsAbstand);
    await pflege.nachSuche();
    await pflege.erledigt();
    expect(
      _enthaelt(nachbau.received.sublist(vorher), const <int>[0x1D, 0x49]),
      isFalse,
    );

    // … noch nach einer Umbenennung derselben Adresse (PUT).
    final alt = await gespeichert();
    await a.registry.upsert(
      PrinterConfig(
        id: alt.id,
        name: 'Theke',
        kind: alt.kind,
        host: alt.host,
        port: alt.port,
      ),
    );
    expect((await gespeichert()).idQueryUnansweredAt, isNotNull);
    vorher = nachbau.received.length;
    await pflege.nachAnlegen(id);
    expect(
      _enthaelt(nachbau.received.sublist(vorher), const <int>[0x1D, 0x49]),
      isFalse,
    );

    // Eine neue Adresse: dort kann ein anderes Gerät stehen – neu gefragt.
    await a.registry.upsert(
      PrinterConfig(
        id: alt.id,
        name: 'Theke',
        kind: alt.kind,
        host: 'localhost',
        port: alt.port,
      ),
    );
    final neu = await gespeichert();
    expect(neu.idQueryUnansweredAt, isNull);
    expect(neu.idQueryMissedAt, isNull);
    vorher = nachbau.received.length;
    await pflege.nachAnlegen(id);
    expect(_enthaelt(nachbau.received.sublist(vorher), _gsI(67)), isTrue);
  });

  test('Sollte 3: zu knapp gefragt oder während der eigene Bon druckt, '
      'zählt ein Schweigen auf GS I nicht', () async {
    final knapp = Kennungspflege(
      store: a.store,
      queue: a.queue,
      lagen: a.registry.lagen,
      log: a.log,
      clock: () => a.jetzt,
      erkennung: DruckerErkennung(
        abfrage: EscPosAbfrage(
          verbinden: nachbau.verbinden,
          aufbauGrenze: testAufbauGrenze,
        ),
        arp: a.arp,
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
        budget: const Duration(milliseconds: 500), // unter gsIVolleFrist
      ),
    );
    final id = await a.drucker(nachbau.port, model: null);
    await knapp.nachAnlegen(id);
    expect(_enthaelt(nachbau.received, _gsI(67)), isTrue, reason: 'gefragt');
    expect((await gespeichert()).idQueryMissedAt, isNull, reason: 'zu knapp');

    // Volle Frist, aber der eigene Bon druckt noch.
    a.registry.lagen.von(id).druckGesendet(8000, a.jetzt);
    await pflege.nachAnlegen(id);
    expect((await gespeichert()).idQueryMissedAt, isNull, reason: 'druckt');

    // Danach zählt es.
    a.jetzt = a.jetzt.add(druckNachlauf(8000));
    await pflege.nachAnlegen(id);
    expect((await gespeichert()).idQueryMissedAt, isNotNull);
  });

  test('GS I 67 ohne gültigen Rahmen (hier sofort unbrauchbar): kein '
      'GS I 68 mehr auf derselben Verbindung', () async {
    nachbau.gsIRoh[67] = const <int>[0x5F, 0x00]; // leerer Rahmen
    nachbau.gsI[68] = 'X5ZT000123';
    final antworten = await EscPosAbfrage(verbinden: nachbau.verbinden).frage(
      '127.0.0.1',
      nachbau.port,
      fragen: const <EscPosFrage>{EscPosFrage.modell, EscPosFrage.seriennummer},
      budget: const Duration(seconds: 2),
    );
    expect(antworten.offlineGrund, 0x12);
    expect(antworten.modell, isNull);
    expect(antworten.gsIOhneAntwort, isTrue);
    expect(antworten.seriennummer, isNull);
    await nachbau.ruhigNachVerbindung();
    expect(_enthaelt(nachbau.received, _gsI(68)), isFalse);
  });

  test('ein Drucker, der GS I 67 beantwortet, bekommt weiter GS I', () async {
    nachbau.gsI.addAll(const <int, String>{67: 'TM-T88VI', 68: 'X5ZT000123'});
    final id = await a.drucker(nachbau.port, model: null);
    await pflege.nachAnlegen(id);
    final nach = await gespeichert();
    expect(nach.model, 'TM-T88VI');
    expect(nach.serial, 'X5ZT000123');
    expect(nach.idQueryUnansweredAt, isNull);
  });

  test('idQueryUnansweredAt und idQueryMissedAt überstehen den Rundlauf; '
      'behalteKennung behält sie nur an derselben Adresse', () {
    final am = DateTime.utc(2026, 11, 11, 9);
    final d = PrinterConfig(
      id: 'p1',
      name: 'Bon',
      kind: PrinterKind.tcp9100,
      host: '192.168.0.50',
      idQueryUnansweredAt: am,
    );
    expect(d.toJson()['idQueryUnansweredAt'], '2026-11-11T09:00:00.000Z');
    expect(PrinterConfig.fromJson(d.toJson()).idQueryUnansweredAt, am);
    expect(d.toApiJson().containsKey('idQueryUnansweredAt'), isFalse);
    final ohne = PrinterConfig(
      id: 'p1',
      name: 'Bon',
      kind: PrinterKind.tcp9100,
      host: '192.168.0.50',
    );
    expect(ohne.toJson().containsKey('idQueryUnansweredAt'), isFalse);
    expect(ohne.toJson().containsKey('idQueryMissedAt'), isFalse);

    final vermerkt = d.copyWith(idQueryMissedAt: am);
    expect(PrinterConfig.fromJson(vermerkt.toJson()).idQueryMissedAt, am);
    final umbenannt = PrinterRegistry.behalteKennung(
      vermerkt,
      ohne.copyWith(name: 'Theke'),
    );
    expect(umbenannt.idQueryUnansweredAt, am);
    expect(umbenannt.idQueryMissedAt, am);
    final andereAdresse = PrinterRegistry.behalteKennung(
      vermerkt,
      ohne.copyWith(host: '192.168.0.51'),
    );
    expect(andereAdresse.idQueryUnansweredAt, isNull);
    expect(andereAdresse.idQueryMissedAt, isNull);
    final verworfen = PrinterRegistry.behalteKennung(
      vermerkt,
      ohne,
      kennungVerwerfen: true,
    );
    expect(verworfen.idQueryUnansweredAt, isNull, reason: 'anderes Gerät');
  });
}
