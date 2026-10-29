import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:kasseneck_connect/src/bluetooth/connections.dart';
import 'package:kasseneck_connect/src/bluetooth/helper.dart';
import 'package:kasseneck_connect/src/bluetooth/protocol.dart';
import 'package:kasseneck_connect/src/events/bus.dart';
import 'package:kasseneck_connect/src/log/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_bluetooth.dart';

const String _ff00 = '0000ff00-0000-1000-8000-00805f9b34fb';
const String _ff01 = '0000ff01-0000-1000-8000-00805f9b34fb';
const String _ff03 = '0000ff03-0000-1000-8000-00805f9b34fb';

/// Kennung, die der nachgespielte Mac nicht kennt (erfunden).
const String _fremdeId = '7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f';

const String _unerreichbar =
    'Nicht erreichbar – vielleicht mit einem anderen Gerät verbunden.';

/// Ausgang eines Aufrufs, ohne `await` – in `fakeAsync` läuft die Zeit nur
/// auf Zuruf.
class _Ausgang<T> {
  T? wert;
  Object? fehler;
  bool fertig = false;

  String? get code => switch (fehler) {
    BluetoothFailure(:final code) => code,
    _ => null,
  };
}

_Ausgang<T> _verfolge<T>(Future<T> aufruf) {
  final ausgang = _Ausgang<T>();
  unawaited(
    aufruf.then<void>(
      (wert) {
        ausgang
          ..wert = wert
          ..fertig = true;
      },
      onError: (Object fehler) {
        ausgang
          ..fehler = fehler
          ..fertig = true;
      },
    ),
  );
  return ausgang;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Ein Ereignis kurz und lesbar, für Reihenfolge-Vergleiche.
String _kurz(AgentEvent e) => switch (e.type) {
  eventBluetoothState => 'zustand ${e.data['state']}',
  eventBluetoothDevice when e.data['connected'] == true =>
    'verbunden ${e.data['generation']}',
  eventBluetoothDevice =>
    'getrennt ${e.data['generation']} (${e.data['reason']})',
  eventBluetoothNotification =>
    'meldung ${e.data['generation']}#${e.data['seq']} '
        '${_hex(base64Decode(e.data['data']! as String))}',
  _ => e.type,
};

Map<String, Object?> _schreiben(List<int> bytes) => {
  'device': fakeM110Id,
  'service': 'ff00',
  'characteristic': 'ff02',
  'data': base64Encode(bytes),
  'withResponse': true,
};

final DateTime _start = DateTime.utc(2026, 10, 29, 9);

/// Verbindungen über der Attrappe des Hilfsprogramms mit einem M110.
class _Aufbau {
  _Aufbau(this.async, AgentLog log, {FakeM110? m110})
    : m110 = m110 ?? FakeM110() {
    fake = FakeBluetoothHelper(log: log, geraete: [this.m110]);
    conns = BluetoothConnections(
      helper: fake,
      events: bus,
      log: log,
      clock: () => _start.add(async.elapsed),
    );
    bus.stream.listen(ereignisse.add);
  }

  final FakeAsync async;
  final FakeM110 m110;
  late final FakeBluetoothHelper fake;
  late final BluetoothConnections conns;
  final EventBus bus = EventBus();
  final List<AgentEvent> ereignisse = <AgentEvent>[];

  int get connects =>
      fake.befehle.where((b) => b.op == HelperOp.connect).length;

  int get abos => fake.befehle.where((b) => b.op == HelperOp.subscribe).length;

  List<Map<String, Object?>> get geraet => [
    for (final e in ereignisse)
      if (e.type == eventBluetoothDevice) e.data,
  ];

  /// Alle Ereignisse außer `bluetooth.state`, kurz.
  List<String> get ablauf => [
    for (final e in ereignisse)
      if (e.type != eventBluetoothState) _kurz(e),
  ];

  List<String> get zustaende => [
    for (final e in ereignisse)
      if (e.type == eventBluetoothState) e.data['state']! as String,
  ];

  int verbinden() {
    final a = _verfolge(conns.demand(fakeM110Id));
    async.flushMicrotasks();
    expect(a.fehler, isNull);
    return a.wert!;
  }

  void abonnieren([String characteristic = 'ff03']) {
    final a = _verfolge(conns.subscribe(fakeM110Id, 'ff00', characteristic));
    async.flushMicrotasks();
    expect(a.fehler, isNull);
    expect(a.fertig, isTrue);
  }

  void schreiben(List<int> bytes) {
    final a = _verfolge(fake.call(HelperOp.write, _schreiben(bytes)));
    async.flushMicrotasks();
    expect(a.fehler, isNull);
  }

  List<String> gepuffert() => [
    for (final n in conns.notifications(fakeM110Id))
      '${n.generation}#${n.seq} ${_hex(n.data)}',
  ];

  void ende() {
    unawaited(conns.close());
    unawaited(fake.stop());
    async.elapse(const Duration(seconds: 5));
  }
}

void main() {
  late Directory temp;
  late AgentLog log;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-bt-conns-');
    log = AgentLog(
      Directory(p.join(temp.path, 'logs')),
      minimumLevel: LogLevel.debug,
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String logText() => log.file.existsSync() ? log.file.readAsStringSync() : '';

  test('demand verbindet einmal und verlängert danach nur', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      // Gleichzeitig und in anderer Schreibweise: ein einziger Verbindungsaufbau.
      final erster = _verfolge(t.conns.demand(fakeM110Id));
      final zweiter = _verfolge(t.conns.demand(fakeM110Id.toUpperCase()));
      async.flushMicrotasks();
      expect(erster.wert, 1);
      expect(zweiter.wert, 1);
      expect(t.connects, 1);
      expect(t.m110.verbindungen, 1);
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.conns.generationOf(fakeM110Id), 1);
      expect(t.conns.maxWriteLength(fakeM110Id), (
        withResponse: 512,
        withoutResponse: 20,
      ));

      // Ein erneutes `connected` derselben Verbindung ist keine neue.
      t.fake.sendeZeile(
        jsonEncode({
          'event': 'connected',
          'device': fakeM110Id,
          'maxWriteWithResponse': 512,
          'maxWriteWithoutResponse': 20,
        }),
      );
      async.flushMicrotasks();
      expect(t.conns.generationOf(fakeM110Id), 1);
      expect(t.geraet, hasLength(1));

      async.elapse(const Duration(seconds: 50));
      expect(t.verbinden(), 1);
      expect(t.connects, 1);

      // Das Nachhalten zählt ab dem letzten Zugriff.
      async.elapse(const Duration(seconds: 59));
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.m110.verbunden, isFalse);
      expect(t.connects, 1);
      expect(t.geraet, [
        {'id': fakeM110Id, 'connected': true, 'generation': 1},
        {
          'id': fakeM110Id,
          'connected': false,
          'generation': 1,
          'reason': 'idle',
        },
      ]);
      t.ende();
    });
  });

  test('nach 60 s ohne Zugriff wird getrennt und freigegeben', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      expect(t.gepuffert(), ['1#1 02 b6 00']);

      async.elapse(const Duration(seconds: 59));
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.m110.verbunden, isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.conns.maxWriteLength(fakeM110Id), isNull);
      expect(t.conns.notifications(fakeM110Id), isEmpty);
      expect(t.fake.befehle.last.op, HelperOp.disconnect);
      // Frei für andere Geräte: Connect hält keine Verbindung mehr.
      expect(t.m110.verbunden, isFalse);
      expect(t.geraet.last['reason'], 'idle');

      // Abos und Puffer sind verworfen: der nächste Bedarf beginnt ohne ff03.
      async.elapse(const Duration(minutes: 5));
      expect(t.connects, 1);
      expect(t.verbinden(), 2);
      expect(t.abos, 1);
      expect(t.m110.abonniert, isFalse);
      expect(t.conns.notifications(fakeM110Id), isEmpty);
      t.ende();
    });
  });

  test('hold verhindert das Trennen, unhold startet das Nachhalten neu', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      async.elapse(const Duration(seconds: 30));
      t.conns.hold(fakeM110Id);
      async.elapse(const Duration(minutes: 5));
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.m110.verbunden, isTrue);

      t.conns.unhold(fakeM110Id);
      // Ein überzähliges unhold verlängert nichts und stört nicht.
      t.conns.unhold(fakeM110Id);
      async.elapse(const Duration(seconds: 59));
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.m110.verbunden, isFalse);
      expect(t.ablauf, ['verbunden 1', 'getrennt 1 (idle)']);
      t.ende();
    });
  });

  test('Abbruch während des Bedarfs: neu verbinden, ff03 wieder abonniert, '
      'Verbindungsnummer +1', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      // Gehalten = mitten in einem Druck.
      t.conns.hold(fakeM110Id);
      t.ereignisse.clear();
      // Wer „verbunden“ hört, muss sich auf das Abo verlassen können.
      final abonniertBeimMelden = <bool>[];
      t.bus.stream
          .where(
            (e) =>
                e.type == eventBluetoothDevice && e.data['connected'] == true,
          )
          .listen((_) => abonniertBeimMelden.add(t.m110.abonniert));

      t.m110.verbindungAbbrechen();
      async.flushMicrotasks();
      expect(t.connects, 2);
      expect(t.m110.verbindungen, 2);
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.conns.generationOf(fakeM110Id), 2);
      expect(t.m110.abonniert, isTrue);
      expect(abonniertBeimMelden, [true]);
      // Erst die neue Verbindungsnummer, dann die Meldungen unter ihr.
      expect(t.ablauf, [
        'getrennt 1 (peripheral disconnected)',
        'verbunden 2',
        'meldung 2#2 02 b6 00',
      ]);

      // Rot-Probe: ohne wiederhergestelltes Abo käme hier keine Meldung.
      t.schreiben([1, 2, 3]);
      expect(t.ablauf.last, 'meldung 2#3 01 01');
      expect(t.gepuffert(), ['2#2 02 b6 00', '2#3 01 01']);
      async.elapse(const Duration(seconds: 3));
      expect(t.m110.etiketten, 1);
      expect(t.ablauf.last, 'meldung 2#4 1a 0f 0c');
      t.ende();
    });
  });

  test('Drucker trennt leere Verbindung ohne Bedarf: kein Neuverbinden', () {
    fakeAsync((async) {
      final m110 = FakeM110()
        ..trenntLeereVerbindungNach = const Duration(seconds: 30);
      final t = _Aufbau(async, log, m110: m110);
      t.verbinden();
      t.abonnieren();

      // Nach dem letzten Zugriff hält Connect nur nach; trennt der Drucker die
      // leere Verbindung, bleibt sie zu.
      async.elapse(const Duration(seconds: 30));
      expect(m110.verbunden, isFalse);
      expect(t.ablauf.last, 'getrennt 1 (peripheral disconnected)');
      async.elapse(const Duration(seconds: 25));
      expect(t.connects, 1);
      expect(m110.verbindungen, 1);
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.conns.maxWriteLength(fakeM110Id), isNull);
      expect(t.conns.notifications(fakeM110Id), isEmpty);

      // Der nächste Bedarf verbindet und bringt das Abo dieses Bedarfs mit.
      expect(t.verbinden(), 2);
      expect(m110.abonniert, isTrue);
      expect(t.gepuffert(), ['2#2 02 b6 00']);
      t.ende();
    });
  });

  test('Bluetooth aus ohne Halten: erst der nächste Bedarf verbindet', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.fake.setzeZustand('poweredOff');
      async.flushMicrotasks();
      expect(t.ablauf.last, 'getrennt 1 (bluetooth poweredOff)');
      t.fake.setzeZustand('poweredOn');
      async.elapse(const Duration(seconds: 20));
      expect(t.connects, 1);
      expect(t.conns.isConnected(fakeM110Id), isFalse);

      expect(t.verbinden(), 2);
      expect(t.m110.abonniert, isTrue);
      t.ende();
    });
  });

  test('von anderem Gerät gehalten: bluetooth_unreachable nach 10 s', () {
    fakeAsync((async) {
      final m110 = FakeM110()..vonAnderemGeraetGehalten = true;
      final t = _Aufbau(async, log, m110: m110);
      final verbinden = _verfolge(t.conns.demand(fakeM110Id));
      async.elapse(const Duration(milliseconds: 9999));
      expect(verbinden.fertig, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(verbinden.code, 'bluetooth_unreachable');
      expect((verbinden.fehler! as BluetoothFailure).message, _unerreichbar);
      // Der wartende Verbindungsaufbau wird abgebrochen; dessen spätes
      // not_connected bleibt folgenlos.
      expect(t.fake.befehle.map((b) => b.op), [
        HelperOp.connect,
        HelperOp.disconnect,
      ]);
      expect(t.conns.isConnected(fakeM110Id), isFalse);

      // Gibt die Kassen-App ihn frei, greift Connect nicht von selbst zu.
      m110.vonAnderemGeraetGehalten = false;
      async.elapse(const Duration(minutes: 1));
      expect(m110.verbindungen, 0);
      expect(t.geraet, isEmpty);
      expect(t.conns.generationOf(fakeM110Id), 0);

      // Erst der nächste Bedarf verbindet – sofort.
      expect(t.verbinden(), 1);
      expect(logText(), contains('nicht erreichbar'));
      t.ende();
    });
  });

  test('spätes not_connected nach einem Abbruch: ein zweiter Versuch im '
      'selben Zeitlimit', () {
    fakeAsync((async) {
      final m110 = FakeM110()..vonAnderemGeraetGehalten = true;
      final t = _Aufbau(async, log, m110: m110);
      final verbinden = _verfolge(t.conns.demand(fakeM110Id));
      async.elapse(const Duration(seconds: 3));
      // Ein übrig gebliebener Abbruch beantwortet das offene connect.
      m110.verbindungAbbrechen('connect cancelled');
      async.flushMicrotasks();
      expect(t.connects, 2);
      expect(verbinden.fertig, isFalse);
      async.elapse(const Duration(milliseconds: 6999));
      expect(verbinden.fertig, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(verbinden.code, 'bluetooth_unreachable');

      // Klappt der zweite Versuch, ist die Verbindung da.
      final nochmal = _verfolge(t.conns.demand(fakeM110Id));
      async.elapse(const Duration(seconds: 1));
      m110.verbindungAbbrechen('connect cancelled');
      m110.vonAnderemGeraetGehalten = false;
      async.flushMicrotasks();
      expect(nochmal.wert, 1);
      expect(t.connects, 4);
      t.ende();
    });
  });

  test('unbekannte Kennung: bluetooth_device_not_found sofort', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      final verbinden = _verfolge(t.conns.demand(_fremdeId));
      async.flushMicrotasks();
      expect(verbinden.code, 'bluetooth_device_not_found');
      expect(
        (verbinden.fehler! as BluetoothFailure).message,
        contains('neu suchen'),
      );
      expect(t.fake.befehle.map((b) => b.op), [HelperOp.connect]);
      async.elapse(const Duration(seconds: 30));
      expect(t.fake.befehle.map((b) => b.op), [HelperOp.connect]);
      expect(t.conns.isConnected(_fremdeId), isFalse);
      t.ende();
    });
  });

  test('Puffer hält die letzten 32 Meldungen der laufenden Verbindung', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren(); // 02 b6 00, seq 1
      // Ein zweites Merkmal hat seinen eigenen Puffer.
      t.fake.sendeZeile(
        jsonEncode({
          'event': 'notification',
          'device': fakeM110Id,
          'service': 'ff00',
          'characteristic': 'ff01',
          'data': base64Encode([7]),
        }),
      );
      async.flushMicrotasks();
      for (var i = 0; i < 40; i++) {
        t.schreiben([i]); // je 01 01, seq 3 bis 42
      }

      final liste = t.conns.notifications(fakeM110Id);
      final ff03 = liste.where((n) => n.characteristic == _ff03).toList();
      expect(ff03, hasLength(32));
      expect(ff03.first.seq, 11);
      expect(ff03.last.seq, 42);
      expect(ff03.map((n) => _hex(n.data)), everyElement('01 01'));
      final ff01 = liste.where((n) => n.characteristic == _ff01).single;
      expect(ff01.data, [7]);
      expect(ff01.service, _ff00);
      expect(ff01.seq, 2);
      expect(
        liste.map((n) => n.seq),
        orderedEquals([2, for (var s = 11; s <= 42; s++) s]),
      );
      expect(liste.map((n) => n.generation), everyElement(1));

      // Neue Verbindung: nur noch Meldungen der laufenden Verbindungsnummer.
      t.conns.hold(fakeM110Id);
      t.m110.verbindungAbbrechen();
      async.flushMicrotasks();
      expect(t.gepuffert(), ['2#43 02 b6 00']);
      t.ende();
    });
  });

  test('Ereignisse tragen Verbindungsnummer und seq', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.schreiben([1]);
      expect(t.zustaende, ['starting', 'poweredOn']);
      expect(
        t.ereignisse
            .where((e) => e.type != eventBluetoothState)
            .map((e) => e.toJson()),
        [
          {
            'type': 'bluetooth.device',
            'id': fakeM110Id,
            'connected': true,
            'generation': 1,
          },
          {
            'type': 'bluetooth.notification',
            'id': fakeM110Id,
            'service': _ff00,
            'characteristic': _ff03,
            'data': 'ArYA',
            'generation': 1,
            'seq': 1,
          },
          {
            'type': 'bluetooth.notification',
            'id': fakeM110Id,
            'service': _ff00,
            'characteristic': _ff03,
            'data': 'AQE=',
            'generation': 1,
            'seq': 2,
          },
        ],
      );
      expect(t.conns.notifications(fakeM110Id).first.toJson(), {
        'service': _ff00,
        'characteristic': _ff03,
        'data': 'ArYA',
        'at': '2026-10-29T09:00:00.000Z',
        'generation': 1,
        'seq': 1,
      });

      // seq zählt über Verbindungen hinweg weiter.
      t.conns.hold(fakeM110Id);
      t.ereignisse.clear();
      t.m110.verbindungAbbrechen();
      async.flushMicrotasks();
      t.schreiben([2]);
      expect(t.ablauf, [
        'getrennt 1 (peripheral disconnected)',
        'verbunden 2',
        'meldung 2#3 02 b6 00',
        'meldung 2#4 01 01',
      ]);
      t.ende();
    });
  });

  test('Bluetooth aus während Bedarf: nach poweredOn neu verbunden', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.conns.hold(fakeM110Id);
      t.ereignisse.clear();

      t.fake.setzeZustand('poweredOff');
      async.flushMicrotasks();
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.zustaende, ['poweredOff']);
      expect(t.ablauf, ['getrennt 1 (bluetooth poweredOff)']);

      // Wer jetzt verbinden will, erfährt sofort, dass Bluetooth aus ist.
      final aus = _verfolge(t.conns.demand(fakeM110Id));
      async.flushMicrotasks();
      expect(aus.code, HelperErrorCode.bluetoothOff);
      final versuche = t.connects;
      // Kein Dauerversuch, solange Bluetooth aus ist.
      async.elapse(const Duration(minutes: 2));
      expect(t.connects, versuche);

      t.fake.setzeZustand('poweredOn');
      async.flushMicrotasks();
      expect(t.connects, versuche + 1);
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.conns.generationOf(fakeM110Id), 2);
      expect(t.m110.abonniert, isTrue);
      expect(t.ablauf, [
        'getrennt 1 (bluetooth poweredOff)',
        'verbunden 2',
        'meldung 2#2 02 b6 00',
      ]);
      t.ende();
    });
  });

  test('reset trennt; gehalten wird neu verbunden, sonst erst beim nächsten '
      'Bedarf', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.conns.hold(fakeM110Id);
      t.ereignisse.clear();

      final zurueck = _verfolge(t.conns.reset(fakeM110Id));
      async.flushMicrotasks();
      expect(zurueck.fertig, isTrue);
      expect(t.conns.generationOf(fakeM110Id), 2);
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.m110.abonniert, isTrue);
      expect(t.ablauf, [
        'getrennt 1 (reset)',
        'verbunden 2',
        'meldung 2#2 02 b6 00',
      ]);

      t.conns.unhold(fakeM110Id);
      final ohne = _verfolge(t.conns.reset(fakeM110Id));
      async.flushMicrotasks();
      expect(ohne.fertig, isTrue);
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.connects, 2);
      expect(t.verbinden(), 3);
      expect(t.m110.abonniert, isTrue);
      t.ende();
    });
  });

  test('reset bei Bluetooth aus: genau ein Neuverbinden nach poweredOn', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.conns.hold(fakeM110Id);
      t.fake.setzeZustand('poweredOff');
      async.flushMicrotasks();
      t.ereignisse.clear();

      final erstes = _verfolge(t.conns.reset(fakeM110Id));
      final zweites = _verfolge(t.conns.reset(fakeM110Id));
      async.flushMicrotasks();
      expect(erstes.fertig, isTrue);
      expect(zweites.fertig, isTrue);
      final versuche = t.connects;

      t.fake.setzeZustand('poweredOn');
      async.elapse(const Duration(seconds: 30));
      expect(t.connects, versuche + 1);
      expect(t.ablauf, ['verbunden 2', 'meldung 2#2 02 b6 00']);
      t.ende();
    });
  });

  test('release beendet den Bedarf sofort: trennt, verwirft Abos, ein '
      'wartendes demand scheitert', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.conns.hold(fakeM110Id);

      final frei = _verfolge(t.conns.release(fakeM110Id));
      async.flushMicrotasks();
      expect(frei.fertig, isTrue);
      expect(frei.fehler, isNull);
      expect(t.m110.verbunden, isFalse);
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.conns.notifications(fakeM110Id), isEmpty);
      expect(t.ablauf.last, 'getrennt 1 (released)');
      // Gehalten war es auch: kein Neuverbinden, auch nicht später.
      async.elapse(const Duration(minutes: 2));
      expect(t.connects, 1);
      expect(t.verbinden(), 2);
      expect(t.m110.abonniert, isFalse);

      // Während eines wartenden Verbindungsaufbaus.
      unawaited(t.conns.release(fakeM110Id));
      async.flushMicrotasks();
      t.m110.vonAnderemGeraetGehalten = true;
      final wartet = _verfolge(t.conns.demand(fakeM110Id));
      async.elapse(const Duration(seconds: 2));
      unawaited(t.conns.release(fakeM110Id));
      async.flushMicrotasks();
      expect(wartet.code, 'bluetooth_disconnected');
      expect(t.fake.befehle.last.op, HelperOp.disconnect);
      t.m110.vonAnderemGeraetGehalten = false;
      async.elapse(const Duration(seconds: 30));
      expect(t.m110.verbunden, isFalse);
      t.ende();
    });
  });

  test('Hilfsprogramm stürzt ab während des Haltens: neu gestartet, neu '
      'verbunden, Abo wieder da', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.conns.hold(fakeM110Id);
      t.ereignisse.clear();

      t.fake.abstuerzen();
      async.flushMicrotasks();
      expect(t.zustaende, ['helper_restarting']);
      expect(t.ablauf, ['getrennt 1 (bluetooth helper exited)']);
      async.elapse(const Duration(seconds: 2));
      expect(t.fake.starts, 2);
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      expect(t.conns.generationOf(fakeM110Id), 2);
      expect(t.m110.abonniert, isTrue);
      expect(t.zustaende, ['helper_restarting', 'poweredOn']);
      expect(t.ablauf, [
        'getrennt 1 (bluetooth helper exited)',
        'verbunden 2',
        'meldung 2#2 02 b6 00',
      ]);
      t.ende();
    });
  });

  test('Abo lässt sich nicht wiederherstellen: nie als verbunden gemeldet', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      t.conns.hold(fakeM110Id);
      t.ereignisse.clear();
      // Das Merkmal kann nach dem Abbruch nicht mehr melden.
      t.m110.dienste[_ff00]![_ff03] = ['read'];

      t.m110.verbindungAbbrechen();
      async.flushMicrotasks();
      expect(t.conns.isConnected(fakeM110Id), isFalse);
      expect(t.m110.verbunden, isFalse);
      expect(t.ablauf, ['getrennt 1 (peripheral disconnected)']);

      final verbinden = _verfolge(t.conns.demand(fakeM110Id));
      async.flushMicrotasks();
      expect(verbinden.code, HelperErrorCode.unsupportedOperation);
      expect(t.m110.verbunden, isFalse);
      expect(t.ablauf, ['getrennt 1 (peripheral disconnected)']);
      expect(logText(), contains('nicht wiederhergestellt'));

      // Ein neuer Bedarf ohne das alte Abo geht.
      unawaited(t.conns.release(fakeM110Id));
      async.flushMicrotasks();
      expect(t.verbinden(), greaterThan(2));
      expect(t.conns.isConnected(fakeM110Id), isTrue);
      t.ende();
    });
  });

  test('Log: kurze Meldungen als Hex, längere nie mit Inhalt', () {
    fakeAsync((async) {
      final t = _Aufbau(async, log);
      t.verbinden();
      t.abonnieren();
      final lang = [for (var i = 0; i < 12; i++) 0xa0 + i];
      t.fake.sendeZeile(
        jsonEncode({
          'event': 'notification',
          'device': fakeM110Id,
          'service': 'ff00',
          'characteristic': 'ff03',
          'data': base64Encode(lang),
        }),
      );
      async.flushMicrotasks();
      expect(t.gepuffert().last, '1#2 ${_hex(lang)}');
      final text = logText();
      expect(text, contains('02 b6 00'));
      expect(text, contains('12 Byte'));
      expect(text, isNot(contains(_hex(lang))));
      expect(text, isNot(contains(_hex(lang.sublist(0, 4)))));
      expect(text, isNot(contains(base64Encode(lang))));
      t.ende();
    });
  });
}
