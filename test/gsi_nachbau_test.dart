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
        // Kurz: der Nachbau antwortet auf GS I nie.
        budget: const Duration(milliseconds: 600),
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

  test('nach dem Anlegen einmal GS I 67, kein GS I 68; danach auf Zuruf nur '
      'DLE EOT; eine Neueinrichtung (PUT) fragt wieder', () async {
    final id = await a.drucker(nachbau.port, model: null);
    await pflege.nachAnlegen(id);
    var bytes = nachbau.received.toList();
    expect(_enthaelt(bytes, _gsI(67)), isTrue, reason: 'beim Anlegen');
    expect(_enthaelt(bytes, _gsI(68)), isFalse, reason: 'nach stummem 67');
    final nach = await gespeichert();
    expect(nach.idQueryUnansweredAt, isNotNull);
    expect(nach.statusCapableAt, isNotNull, reason: 'DLE EOT beantwortet');
    expect(nach.model, isNull);

    // Auf Zuruf (Suche, Statusabfrage) nach dem Abstand: nur DLE EOT.
    a.jetzt = a.jetzt.add(erkennungsAbstand);
    final vorher = nachbau.received.length;
    await pflege.aufZuruf(id);
    bytes = nachbau.received.sublist(vorher);
    expect(bytes, isNotEmpty, reason: 'DLE EOT ging hinaus');
    expect(_enthaelt(bytes, const <int>[0x1D, 0x49]), isFalse);
    a.jetzt = a.jetzt.add(erkennungsAbstand);
    await pflege.nachSuche();
    await pflege.erledigt();
    expect(
      _enthaelt(nachbau.received.sublist(vorher), const <int>[0x1D, 0x49]),
      isFalse,
    );

    // Die Kasse richtet ihn neu ein: das Feld fällt weg, GS I geht wieder.
    final alt = await gespeichert();
    await a.registry.upsert(
      PrinterConfig(
        id: alt.id,
        name: alt.name,
        kind: alt.kind,
        host: alt.host,
        port: alt.port,
      ),
    );
    expect((await gespeichert()).idQueryUnansweredAt, isNull);
    final vorPut = nachbau.received.length;
    await pflege.nachAnlegen(id);
    expect(_enthaelt(nachbau.received.sublist(vorPut), _gsI(67)), isTrue);
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

  test('idQueryUnansweredAt übersteht den Rundlauf durch die config.json', () {
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
  });
}
