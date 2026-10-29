import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:kasseneck_connect/src/bluetooth/bridge.dart';
import 'package:kasseneck_connect/src/bluetooth/helper.dart';
import 'package:kasseneck_connect/src/bluetooth/leases.dart';
import 'package:kasseneck_connect/src/bluetooth/protocol.dart';
import 'package:kasseneck_connect/src/bluetooth/uuids.dart';
import 'package:kasseneck_connect/src/config/model.dart';
import 'package:kasseneck_connect/src/config/paths.dart';
import 'package:kasseneck_connect/src/config/store.dart';
import 'package:kasseneck_connect/src/events/bus.dart';
import 'package:kasseneck_connect/src/log/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_bluetooth.dart';

const String _ff00 = '0000ff00-0000-1000-8000-00805f9b34fb';

/// Zweiter nachgespielter Drucker (erfunden).
const String _zweiteId = '5b6c7d8e-9fa0-4b1c-8d2e-3f4a5b6c7d8e';

/// Ein Gerät, das keine Suche je gesehen hat (erfunden).
const String _dritteId = '8a7b6c5d-4e3f-4a1b-9c8d-7e6f5a4b3c2d';

final DateTime _start = DateTime.utc(2026, 10, 29, 9);
const String _startIso = '2026-10-29T09:00:00.000Z';

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

List<int> _paket(int fuellung, [int laenge = 180]) =>
    List<int>.filled(laenge, fuellung & 0xff);

int _zaehle(String text, String muster) => muster.allMatches(text).length;

Matcher _scheitertMit(String code) => throwsA(
  isA<BluetoothFailure>()
      .having((f) => f.code, 'code', code)
      .having((f) => f.message, 'message', bluetoothErrorMessages[code]),
);

/// Echter [ConfigStore] im Temp-Verzeichnis, der nur synchron liest: in
/// `fakeAsync` käme echte, asynchrone Datei-Ein-/Ausgabe nie zurück.
/// Geschrieben wird in diesen Tests nicht (dafür laufen die Tests mit dem
/// unveränderten Store außerhalb von `fakeAsync`).
class _SofortLeser extends ConfigStore {
  _SofortLeser(Directory dir) : super(ConfigPaths(dir));

  @override
  Future<AgentConfig> load() {
    final datei = file;
    if (!datei.existsSync()) return Future<AgentConfig>.value(AgentConfig());
    final json = readMap(jsonDecode(datei.readAsStringSync()));
    return Future<AgentConfig>.value(
      json == null ? AgentConfig() : AgentConfig.fromJson(json),
    );
  }
}

/// Schreibt die zugelassenen Geräte direkt in die `config.json`.
void _zulassen(Directory dir, Map<String, String> geraete) {
  final config = AgentConfig(
    bluetoothDevices: [
      for (final e in geraete.entries)
        BluetoothDeviceConfig(id: e.key, name: e.value, approvedAt: _start),
    ],
  );
  ConfigPaths(dir).configFile
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(config.toJson()));
}

/// Liefert die Antworten des Hilfsprogramms auf `read` und `gatt` kaputt.
class _KaputteAntworten implements BluetoothHelper {
  _KaputteAntworten(this._innen);

  final BluetoothHelper _innen;

  @override
  Stream<HelperEvent> get events => _innen.events;

  @override
  String get state => _innen.state;

  @override
  Future<Map<String, Object?>> call(
    String op, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    final ergebnis = await _innen.call(op, args);
    return switch (op) {
      HelperOp.read => <String, Object?>{'data': 'kein Base64 %%%'},
      HelperOp.gatt => <String, Object?>{'services': 'kaputt'},
      _ => ergebnis,
    };
  }

  @override
  Future<void> stop() => _innen.stop();
}

/// Brücke über der Attrappe des Hilfsprogramms, Uhr aus `fakeAsync`.
class _Aufbau {
  _Aufbau(
    this.async,
    Directory dir,
    AgentLog log, {
    List<FakeM110>? geraete,
    Map<String, String>? zugelassen,
    BluetoothHelper Function(FakeBluetoothHelper fake)? huelle,
  }) : geraete = geraete ?? [FakeM110()] {
    _zulassen(dir, zugelassen ?? const {fakeM110Id: 'Q199E00000'});
    fake = FakeBluetoothHelper(log: log, geraete: this.geraete);
    bridge = BluetoothBridge(
      store: _SofortLeser(dir),
      log: log,
      events: bus,
      helper: huelle?.call(fake) ?? fake,
      clock: () => _start.add(async.elapsed + sprung),
    );
    bus.stream.listen((e) {
      switch (e.type) {
        case eventBluetoothDevice when e.data['connected'] == true:
          verlauf.add('verbunden ${e.data['generation']}');
        case eventBluetoothDevice:
          verlauf.add('getrennt ${e.data['generation']} (${e.data['reason']})');
        case eventBluetoothNotification:
          final daten = base64Decode(e.data['data']! as String);
          meldungen.add(
            '${e.data['generation']}#${e.data['seq']} ${_hex(daten)}',
          );
      }
    });
  }

  final FakeAsync async;
  final List<FakeM110> geraete;
  late final FakeBluetoothHelper fake;
  late final BluetoothBridge bridge;
  final EventBus bus = EventBus();

  /// Verbunden/getrennt in Reihenfolge; Tests hängen eigene Marken an.
  final List<String> verlauf = <String>[];

  /// Meldungen als `Verbindungsnummer#seq Hex`.
  final List<String> meldungen = <String>[];

  /// So weit ist die Uhr den Zeitgebern voraus (Ruhezustand).
  Duration sprung = Duration.zero;

  FakeM110 get m110 => geraete.first;

  int befehle(String op) => fake.befehle.where((b) => b.op == op).length;

  /// Führt einen Aufruf bis zum Ende der Mikroaufgaben; er muss gelingen.
  T? ok<T>(Future<T> aufruf) {
    final a = _verfolge(aufruf);
    async.flushMicrotasks();
    expect(a.fehler, isNull);
    expect(a.fertig, isTrue);
    return a.wert;
  }

  /// Führt einen Aufruf bis zum Ende der Mikroaufgaben; er muss scheitern.
  BluetoothFailure fehler(Future<Object?> aufruf) {
    final a = _verfolge(aufruf);
    async.flushMicrotasks();
    expect(a.fehler, isA<BluetoothFailure>());
    return a.fehler! as BluetoothFailure;
  }

  int verbinden([String id = fakeM110Id]) => ok(bridge.connect(id))!;

  void abonnieren() => ok(bridge.subscribe(fakeM110Id, 'ff00', 'ff03'));

  Lease belegen([String id = fakeM110Id]) => ok(bridge.acquireLease(id))!;

  Future<int> schreibe(
    Lease lease,
    List<List<int>> pakete, {
    bool withResponse = true,
    int? generation,
  }) => bridge.write(
    fakeM110Id,
    'ff00',
    'ff02',
    [for (final paket in pakete) Uint8List.fromList(paket)],
    withResponse: withResponse,
    lease: lease.id,
    generation: generation,
  );

  int schreiben(
    Lease lease,
    List<List<int>> pakete, {
    bool withResponse = true,
  }) => ok(schreibe(lease, pakete, withResponse: withResponse))!;

  void ende() {
    unawaited(bridge.close());
    async.elapse(const Duration(seconds: 5));
  }
}

void main() {
  late Directory temp;
  late AgentLog log;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-bt-bridge-');
    log = AgentLog(
      Directory(p.join(temp.path, 'logs')),
      minimumLevel: LogLevel.debug,
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String logText() => log.file.existsSync() ? log.file.readAsStringSync() : '';

  test('nicht zugelassenes Gerät: bluetooth_device_unknown', () {
    fakeAsync((async) {
      // Den M110 kennt der Mac, zugelassen ist aber nur ein anderes Gerät.
      final t = _Aufbau(
        async,
        temp,
        log,
        zugelassen: const {_zweiteId: 'Q199E00001'},
      );
      const lease = 'AAAAAAAAAAAAAAAAAAAAAA';
      final aufrufe = <String, Future<Object?>>{
        'connect': t.bridge.connect(fakeM110Id),
        'release': t.bridge.release(fakeM110Id),
        'gatt': t.bridge.gatt(fakeM110Id),
        'read': t.bridge.read(fakeM110Id, 'ff00', 'ff01'),
        'write': t.bridge.write(
          fakeM110Id,
          'ff00',
          'ff02',
          [Uint8List(4)],
          withResponse: true,
          lease: lease,
        ),
        'subscribe': t.bridge.subscribe(fakeM110Id, 'ff00', 'ff03'),
        'unsubscribe': t.bridge.unsubscribe(fakeM110Id, 'ff00', 'ff03'),
        'acquireLease': t.bridge.acquireLease(fakeM110Id),
      };
      final ausgaenge = {
        for (final e in aufrufe.entries) e.key: _verfolge(e.value),
      };
      async.flushMicrotasks();
      for (final e in ausgaenge.entries) {
        expect(e.value.code, errorBluetoothDeviceUnknown, reason: e.key);
        expect(
          (e.value.fehler! as BluetoothFailure).message,
          bluetoothErrorMessages[errorBluetoothDeviceUnknown],
          reason: e.key,
        );
      }

      // Bluetooth wurde dafür nicht einmal gestartet.
      expect(t.fake.starts, 0);
      expect(t.m110.verbindungen, 0);
      expect(t.bridge.notifications(fakeM110Id), isEmpty);
      expect(t.bridge.renewLease(fakeM110Id, lease), isFalse);
      t.ende();
    });
  });

  test('gesperrter Dienst: lesen, schreiben, abonnieren abgewiesen', () {
    fakeAsync((async) {
      final m110 = FakeM110(
        dienste: {
          'ff00': {
            'ff01': ['read'],
            'ff02': ['write', 'writeWithoutResponse'],
            'ff03': ['notify'],
          },
          // Tastatur (HID): gesperrt.
          '1812': {
            '2a4d': ['read', 'write', 'notify'],
          },
          // Geräteinformation: Hersteller frei, Seriennummer gesperrt.
          '180a': {
            '2a29': ['read'],
            '2a25': ['read'],
          },
        },
      );
      m110.werte[canonicalUuid('2a29')] = Uint8List.fromList(
        utf8.encode('Hersteller'),
      );
      final t = _Aufbau(async, temp, log, geraete: [m110]);
      t.verbinden();
      final lease = t.belegen();

      final dienste = t.ok(t.bridge.gatt(fakeM110Id))!;
      expect(dienste, [
        {
          'uuid': _ff00,
          'characteristics': [
            {
              'uuid': canonicalUuid('ff01'),
              'properties': ['read'],
            },
            {
              'uuid': canonicalUuid('ff02'),
              'properties': ['write', 'writeWithoutResponse'],
            },
            {
              'uuid': canonicalUuid('ff03'),
              'properties': ['notify'],
            },
          ],
        },
        {
          'uuid': canonicalUuid('180a'),
          'characteristics': [
            {
              'uuid': canonicalUuid('2a29'),
              'properties': ['read'],
            },
          ],
        },
      ]);

      const hidLang = '00001812-0000-1000-8000-00805F9B34FB';
      final gesperrt = <String, Future<Object?>>{
        'lesen HID': t.bridge.read(fakeM110Id, '1812', '2a4d'),
        'lesen HID lang': t.bridge.read(fakeM110Id, hidLang, '2A4D'),
        'lesen Seriennummer': t.bridge.read(fakeM110Id, '180a', '2a25'),
        'schreiben HID': t.bridge.write(
          fakeM110Id,
          '1812',
          '2a4d',
          [Uint8List(2)],
          withResponse: true,
          lease: lease.id,
        ),
        'schreiben Seriennummer': t.bridge.write(
          fakeM110Id,
          '180a',
          '2a25',
          [Uint8List(2)],
          withResponse: false,
          lease: lease.id,
        ),
        'abonnieren HID': t.bridge.subscribe(fakeM110Id, '1812', '2a4d'),
        'abo beenden HID': t.bridge.unsubscribe(fakeM110Id, '1812', '2a4d'),
      };
      final ausgaenge = {
        for (final e in gesperrt.entries) e.key: _verfolge(e.value),
      };
      async.flushMicrotasks();
      for (final e in ausgaenge.entries) {
        expect(e.value.code, errorBluetoothBlocked, reason: e.key);
      }
      // Nichts davon ging an das Gerät.
      for (final op in [
        HelperOp.read,
        HelperOp.write,
        HelperOp.subscribe,
        HelperOp.unsubscribe,
      ]) {
        expect(t.befehle(op), 0, reason: op);
      }

      // Ein freies Merkmal derselben Geräteinformation geht.
      final hersteller = t.ok(t.bridge.read(fakeM110Id, '180a', '2a29'))!;
      expect(utf8.decode(hersteller), 'Hersteller');
      t.ende();
    });
  });

  test('Schreiben ohne Belegung: bluetooth_lease_required', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [
          FakeM110(),
          FakeM110(id: _zweiteId, name: 'Q199E00001'),
        ],
        zugelassen: const {fakeM110Id: 'Q199E00000', _zweiteId: 'Q199E00001'},
      );
      t.verbinden();
      t.abonnieren();

      BluetoothFailure ohne(String lease) => t.fehler(
        t.bridge.write(
          fakeM110Id,
          'ff00',
          'ff02',
          [Uint8List.fromList(_paket(0x11, 8))],
          withResponse: true,
          lease: lease,
        ),
      );

      // Erfunden, leer, vom anderen Gerät, schon freigegeben.
      final fremd = t.belegen(_zweiteId);
      final alt = t.belegen();
      expect(t.bridge.releaseLease(fakeM110Id, alt.id), isTrue);
      for (final lease in ['AAAAAAAAAAAAAAAAAAAAAA', '', fremd.id, alt.id]) {
        final f = ohne(lease);
        expect(f.code, errorBluetoothLeaseRequired, reason: lease);
        expect(f.message, bluetoothErrorMessages[errorBluetoothLeaseRequired]);
      }
      expect(t.befehle(HelperOp.write), 0);
      expect(t.m110.pakete, isEmpty);

      // Mit gültiger Belegung geht es.
      final gueltig = t.belegen();
      expect(t.schreiben(gueltig, [_paket(0x11, 8)]), 1);
      expect(t.m110.pakete, hasLength(1));
      t.ende();
    });
  });

  test('zwei Belegungen: Pakete des zweiten Schreibers erst nach Freigabe', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      t.verbinden();
      t.abonnieren();
      List<Uint8List> pakete(int fuellung) => [
        for (var i = 0; i < 5; i++) Uint8List.fromList(_paket(fuellung)),
      ];

      final a = t.belegen();
      // B holt die Belegung und schreibt, sobald es sie hat.
      final b = _verfolge(
        t.bridge.acquireLease(fakeM110Id).then((lease) async {
          final n = await t.bridge.write(
            fakeM110Id,
            'ff00',
            'ff02',
            pakete(0xbb),
            withResponse: true,
            lease: lease.id,
          );
          t.bridge.releaseLease(fakeM110Id, lease.id);
          return n;
        }),
      );

      final a1 = _verfolge(
        t.bridge.write(
          fakeM110Id,
          'ff00',
          'ff02',
          pakete(0xaa),
          withResponse: true,
          lease: a.id,
        ),
      );
      async.elapse(const Duration(seconds: 1));
      expect(a1.wert, 5);
      expect(b.fertig, isFalse);

      final a2 = _verfolge(
        t.bridge.write(
          fakeM110Id,
          'ff00',
          'ff02',
          pakete(0xaa),
          withResponse: true,
          lease: a.id,
        ),
      );
      async.elapse(const Duration(seconds: 1));
      expect(a2.wert, 5);
      expect(b.fertig, isFalse);

      expect(t.bridge.releaseLease(fakeM110Id, a.id), isTrue);
      async.flushMicrotasks();
      expect(b.fehler, isNull);
      expect(b.wert, 5);
      expect(
        [for (final paket in t.m110.pakete) paket.first],
        [...List<int>.filled(10, 0xaa), ...List<int>.filled(5, 0xbb)],
      );
      t.ende();
    });
  });

  test('zwei Schreibaufrufe gleichzeitig: Pakete je Aufruf am Stück', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      t.verbinden();
      t.abonnieren();
      final lease = t.belegen();

      final erster = _verfolge(
        t.schreibe(lease, [for (var i = 0; i < 5; i++) _paket(0xaa)]),
      );
      final zweiter = _verfolge(
        t.schreibe(lease, [for (var i = 0; i < 5; i++) _paket(0xbb)]),
      );
      async.flushMicrotasks();
      expect(erster.wert, 5);
      expect(zweiter.wert, 5);
      expect(
        [for (final paket in t.m110.pakete) paket.first],
        [...List<int>.filled(5, 0xaa), ...List<int>.filled(5, 0xbb)],
      );
      t.ende();
    });
  });

  test('Golden-ähnlicher Auftrag: 64 Pakete mit Antwort, 64 × 01 01, danach '
      '1a 0f 0c als Ereignis', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      expect(t.verbinden(), 1);
      t.abonnieren();
      final lease = t.belegen();

      // Wie die Kasse: ein Aufruf je Paket à 180 Byte.
      for (var i = 0; i < 64; i++) {
        expect(t.schreiben(lease, [_paket(i)]), 1);
      }
      expect(t.m110.etiketten, 0);
      async.elapse(const Duration(milliseconds: 2500));
      expect(t.m110.etiketten, 1);

      expect(t.meldungen, [
        '1#1 02 b6 00',
        for (var i = 0; i < 64; i++) '1#${i + 2} 01 01',
        '1#66 1a 0f 0c',
      ]);
      expect(t.bridge.notifications(fakeM110Id).last.data, [0x1a, 0x0f, 0x0c]);
      expect(t.bridge.releaseLease(fakeM110Id, lease.id), isTrue);

      // Unverändert und in Reihenfolge, je Paket ein Schreibvorgang.
      expect(t.befehle(HelperOp.write), 64);
      expect(t.m110.pakete, [for (var i = 0; i < 64; i++) _paket(i)]);
      expect(t.verlauf, ['verbunden 1']);
      t.ende();
    });
  });

  test('Paket über maxWriteWithoutResponse: bluetooth_write_too_long, '
      'nichts gesendet', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      t.verbinden();
      t.abonnieren();
      final lease = t.belegen();

      final ohne = t.fehler(
        t.schreibe(lease, [
          List<int>.filled(20, 1),
          List<int>.filled(21, 2),
        ], withResponse: false),
      );
      expect(ohne.code, errorBluetoothWriteTooLong);
      expect(ohne.message, bluetoothErrorMessages[errorBluetoothWriteTooLong]);
      expect(ohne.detail, {'written': 0, 'packet': 1, 'length': 21, 'max': 20});

      // Mit Antwort gelten 512 Byte.
      final mit = t.fehler(t.schreibe(lease, [_paket(1), _paket(2, 513)]));
      expect(mit.code, errorBluetoothWriteTooLong);
      expect(mit.detail, {
        'written': 0,
        'packet': 1,
        'length': 513,
        'max': 512,
      });

      expect(t.befehle(HelperOp.write), 0);
      expect(t.m110.pakete, isEmpty);

      // An der Grenze geht beides.
      expect(
        t.schreiben(lease, [List<int>.filled(20, 3)], withResponse: false),
        1,
      );
      expect(t.schreiben(lease, [_paket(4, 512)]), 1);
      expect(t.m110.pakete.map((paket) => paket.length), [20, 512]);
      t.ende();
    });
  });

  test('Belegung läuft ab: Verbindung wird zurückgesetzt, '
      'Verbindungsnummer +1', () {
    fakeAsync((async) {
      // Ein halber Auftrag: der Drucker wartet noch auf den Rest.
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [FakeM110(fertigNach: const Duration(seconds: 30))],
      );
      expect(t.verbinden(), 1);
      t.abonnieren();
      final lease = t.belegen();
      t.schreiben(lease, [for (var i = 0; i < 10; i++) _paket(i)]);

      async.elapse(const Duration(milliseconds: 4999));
      expect(t.bridge.generationOf(fakeM110Id), 1);
      expect(t.verlauf, ['verbunden 1']);

      async.elapse(const Duration(milliseconds: 1));
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (reset)', 'verbunden 2']);
      expect(t.bridge.generationOf(fakeM110Id), 2);
      expect(t.m110.verbunden, isTrue);
      // Das Abo des Bedarfs ist wieder da, der halbe Auftrag verworfen.
      expect(t.m110.abonniert, isTrue);
      expect(t.meldungen.last, '2#12 02 b6 00');
      expect(t.m110.etiketten, 0);
      expect(_zaehle(logText(), 'ohne Freigabe beendet'), 1);

      // Die alte Belegung gilt nicht mehr.
      expect(
        t.fehler(t.schreibe(lease, [_paket(10)])).code,
        errorBluetoothLeaseRequired,
      );
      expect(t.bridge.renewLease(fakeM110Id, lease.id), isFalse);

      // Ohne Belegung hält Connect nur noch nach und gibt dann frei.
      async.elapse(const Duration(seconds: 60));
      expect(t.verlauf.last, 'getrennt 2 (idle)');
      expect(t.m110.etiketten, 0);
      t.ende();
    });
  });

  test('Ablauf während Bluetooth aus, dann poweredOn: genau ein '
      'Zurücksetzen, Agent läuft', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [FakeM110(fertigNach: const Duration(seconds: 30))],
      );
      t.verbinden();
      t.abonnieren();
      final lease = t.belegen();
      t.schreiben(lease, [_paket(1), _paket(2)]);

      async.elapse(const Duration(seconds: 1));
      t.fake.setzeZustand('poweredOff');
      async.flushMicrotasks();
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (bluetooth poweredOff)']);
      final connects = t.befehle(HelperOp.connect);

      // Die Belegung läuft ab, während Bluetooth aus ist.
      async.elapse(const Duration(seconds: 10));
      expect(t.bridge.renewLease(fakeM110Id, lease.id), isFalse);
      expect(_zaehle(logText(), 'ohne Freigabe beendet'), 1);

      t.fake.setzeZustand('poweredOn');
      async.elapse(const Duration(seconds: 30));
      // Kein zweites Zurücksetzen, kein Verbinden ohne Bedarf.
      expect(_zaehle(logText(), 'ohne Freigabe beendet'), 1);
      expect(t.befehle(HelperOp.connect), connects);
      expect(t.m110.verbunden, isFalse);
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (bluetooth poweredOff)']);

      // Der nächste Druck geht ohne Handgriff.
      expect(t.fake.laeuft, isTrue);
      final neu = t.belegen();
      expect(t.verbinden(), 2);
      t.abonnieren();
      expect(t.schreiben(neu, [_paket(3)]), 1);
      expect(t.meldungen.last, '2#5 01 01');
      expect(log.recentErrors, isEmpty);
      t.ende();
    });
  });

  test('nach dem Ablauf wartet eine neue Belegung, bis zurückgesetzt ist, '
      'und bekommt die neue Verbindung', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [FakeM110(fertigNach: const Duration(seconds: 30))],
      );
      t.verbinden();
      t.abonnieren();
      final a = t.belegen();
      t.schreiben(a, [_paket(1)]);

      // Die Kassen-App greift zu: das Neuverbinden nach dem Zurücksetzen
      // dauert, bis sie den Drucker wieder freigibt.
      async.elapse(const Duration(seconds: 4));
      t.m110.vonAnderemGeraetGehalten = true;
      async.elapse(const Duration(seconds: 1));
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (reset)']);

      final b = _verfolge(
        t.bridge.acquireLease(fakeM110Id).then((lease) {
          t.verlauf.add('belegt');
          return lease;
        }),
      );
      async.elapse(const Duration(seconds: 2));
      expect(b.fertig, isFalse);

      t.m110.vonAnderemGeraetGehalten = false;
      async.flushMicrotasks();
      expect(b.fehler, isNull);
      expect(t.verlauf, [
        'verbunden 1',
        'getrennt 1 (reset)',
        'verbunden 2',
        'belegt',
      ]);
      expect(t.bridge.generationOf(fakeM110Id), 2);

      // B schreibt in die neue Verbindung, A nicht mehr.
      expect(
        t.fehler(t.schreibe(a, [_paket(2)])).code,
        errorBluetoothLeaseRequired,
      );
      expect(t.schreiben(b.wert!, [_paket(3)]), 1);
      expect(t.m110.pakete.map((paket) => paket.first), [1, 3]);
      t.ende();
    });
  });

  test('Ruhezustand: eine neue Belegung beendet die abgelaufene selbst und '
      'kommt erst nach dem Zurücksetzen dran', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [FakeM110(fertigNach: const Duration(seconds: 30))],
      );
      t.verbinden();
      t.abonnieren();
      final a = t.belegen();
      t.schreiben(a, [_paket(1)]);

      // Der Mac schläft: die Uhr springt, Zeitgeber laufen nicht. Nach dem
      // Aufwachen hält die Kassen-App den Drucker noch kurz.
      t.sprung = const Duration(minutes: 10);
      t.m110.vonAnderemGeraetGehalten = true;
      final b = _verfolge(
        t.bridge.acquireLease(fakeM110Id).then((lease) {
          t.verlauf.add('belegt');
          return lease;
        }),
      );
      async.flushMicrotasks();
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (reset)']);
      expect(b.fertig, isFalse);

      t.m110.vonAnderemGeraetGehalten = false;
      async.flushMicrotasks();
      expect(b.fehler, isNull);
      expect(t.verlauf, [
        'verbunden 1',
        'getrennt 1 (reset)',
        'verbunden 2',
        'belegt',
      ]);
      expect(t.bridge.renewLease(fakeM110Id, a.id), isFalse);

      // Der stehengebliebene Zeitgeber der alten Belegung meldet kein
      // zweites Ende.
      async.elapse(const Duration(seconds: 4));
      expect(t.bridge.renewLease(fakeM110Id, b.wert!.id), isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(_zaehle(logText(), 'ohne Freigabe beendet'), 1);
      expect(t.verlauf.last, 'belegt');
      t.ende();
    });
  });

  test('Übergabe während stillen Neuverbindens: der Nächste findet das '
      'Gerät verbunden', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      t.verbinden();
      t.abonnieren();
      final a = t.belegen();
      final b = _verfolge(t.bridge.acquireLease(fakeM110Id));
      async.flushMicrotasks();
      expect(b.fertig, isFalse);

      // Der Drucker ist kurz weg; Connect hält ihn und verbindet still neu.
      async.elapse(const Duration(seconds: 1));
      t.m110.aus = true;
      async.flushMicrotasks();
      expect(t.verlauf, [
        'verbunden 1',
        'getrennt 1 (peripheral disconnected)',
      ]);
      final connects = t.befehle(HelperOp.connect);

      // A gibt frei, B kommt dran, während das Neuverbinden noch läuft.
      expect(t.bridge.releaseLease(fakeM110Id, a.id), isTrue);
      async.flushMicrotasks();
      expect(b.wert, isNotNull);
      async.elapse(const Duration(seconds: 1));
      t.m110.aus = false;
      async.flushMicrotasks();

      expect(t.verlauf.last, 'verbunden 2');
      expect(t.m110.verbunden, isTrue);
      expect(t.m110.abonniert, isTrue);
      expect(t.befehle(HelperOp.connect), connects);

      // B schreibt sofort, ohne neuen Verbindungsaufbau.
      expect(t.schreiben(b.wert!, [_paket(7)]), 1);
      expect(t.befehle(HelperOp.connect), connects);
      t.ende();
    });
  });

  test('Freigeben während einer Belegung: bluetooth_busy, das Gerät bleibt '
      'verbunden und gehalten', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      t.verbinden();
      t.abonnieren();
      final a = t.belegen();
      t.schreiben(a, [_paket(1)]);
      final b = _verfolge(t.bridge.acquireLease(fakeM110Id));

      // Ein anderer Tab will das Gerät freigeben, während A druckt.
      final abgewiesen = t.fehler(t.bridge.release(fakeM110Id));
      expect(abgewiesen.code, errorBluetoothBusy);
      expect(abgewiesen.message, bluetoothErrorMessages[errorBluetoothBusy]);
      expect(t.m110.verbunden, isTrue);
      expect(t.verlauf, ['verbunden 1']);
      expect(t.schreiben(a, [_paket(2)]), 1);

      // A gibt frei, B übernimmt; auch jetzt wird nicht freigegeben.
      expect(t.bridge.releaseLease(fakeM110Id, a.id), isTrue);
      async.flushMicrotasks();
      final lease = b.wert!;
      expect(t.fehler(t.bridge.release(fakeM110Id)).code, errorBluetoothBusy);

      // B hält das Gerät: fällt die Verbindung, verbindet Connect still neu …
      t.m110.verbindungAbbrechen();
      async.flushMicrotasks();
      expect(t.verlauf, [
        'verbunden 1',
        'getrennt 1 (peripheral disconnected)',
        'verbunden 2',
      ]);
      // … und das Nachhalten trennt B nicht mitten im Druck.
      for (var i = 0; i < 30; i++) {
        async.elapse(const Duration(seconds: 3));
        expect(t.bridge.renewLease(fakeM110Id, lease.id), isTrue);
      }
      expect(t.m110.verbunden, isTrue);
      expect(t.verlauf.last, 'verbunden 2');
      expect(t.schreiben(lease, [_paket(3)]), 1);

      // Ohne Belegung geht das Freigeben.
      expect(t.bridge.releaseLease(fakeM110Id, lease.id), isTrue);
      async.flushMicrotasks();
      t.ok(t.bridge.release(fakeM110Id));
      expect(t.verlauf.last, 'getrennt 2 (released)');
      expect(t.m110.verbunden, isFalse);
      t.ende();
    });
  });

  test('Freigeben während des Zurücksetzens: bluetooth_busy, das Halten '
      'bleibt im Lot', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [FakeM110(fertigNach: const Duration(seconds: 30))],
      );
      t.verbinden();
      t.abonnieren();
      final a = t.belegen();
      t.schreiben(a, [_paket(1)]);
      final b = _verfolge(t.bridge.acquireLease(fakeM110Id));

      // A läuft ab; das Neuverbinden nach dem Zurücksetzen wartet, weil die
      // Kassen-App den Drucker gerade hält.
      async.elapse(const Duration(seconds: 4));
      t.m110.vonAnderemGeraetGehalten = true;
      async.elapse(const Duration(seconds: 1));
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (reset)']);
      expect(b.fertig, isFalse);

      expect(t.fehler(t.bridge.release(fakeM110Id)).code, errorBluetoothBusy);

      // Das Zurücksetzen endet, B übernimmt das gehaltene Gerät.
      t.m110.vonAnderemGeraetGehalten = false;
      async.flushMicrotasks();
      expect(b.fehler, isNull);
      expect(t.verlauf, ['verbunden 1', 'getrennt 1 (reset)', 'verbunden 2']);
      final lease = b.wert!;
      t.m110.verbindungAbbrechen();
      async.flushMicrotasks();
      expect(t.verlauf.last, 'verbunden 3');
      for (var i = 0; i < 30; i++) {
        async.elapse(const Duration(seconds: 3));
        expect(t.bridge.renewLease(fakeM110Id, lease.id), isTrue);
      }
      expect(t.m110.verbunden, isTrue);
      expect(t.schreiben(lease, [_paket(2)]), 1);
      t.ende();
    });
  });

  test('Verbindung fällt mitten im Schreiben: Abbruch mit written, nichts '
      'in die neue Verbindung', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [FakeM110(fertigNach: const Duration(seconds: 30))],
      );
      expect(t.verbinden(), 1);
      t.abonnieren();
      final lease = t.belegen();

      // Nach dem dritten Paket reißt die Verbindung ab.
      final prozess = t.fake.prozesse.last;
      final weiter = prozess.onZeile!;
      var geschrieben = 0;
      prozess.onZeile = (zeile) {
        weiter(zeile);
        final befehl = decodeHelperLine(zeile);
        if (befehl is HelperRequest &&
            befehl.op == HelperOp.write &&
            ++geschrieben == 3) {
          t.m110.verbindungAbbrechen();
        }
      };

      final f = t.fehler(
        t.schreibe(lease, [for (var i = 0; i < 10; i++) _paket(i)]),
      );
      expect(f.code, errorBluetoothDisconnected);
      expect(f.message, bluetoothErrorMessages[errorBluetoothDisconnected]);
      expect(f.detail, {'written': 3});
      expect(t.m110.pakete, hasLength(3));

      // Gehalten: still neu verbunden, Abo wieder da.
      expect(t.bridge.generationOf(fakeM110Id), 2);
      expect(t.m110.abonniert, isTrue);

      // Wer noch die alte Verbindungsnummer kennt, schreibt nicht in die neue.
      final alt = t.fehler(t.schreibe(lease, [_paket(9)], generation: 1));
      expect(alt.code, errorBluetoothDisconnected);
      expect(alt.detail, {'written': 0});
      expect(t.m110.pakete, hasLength(3));
      expect(t.ok(t.schreibe(lease, [_paket(9)], generation: 2)), 1);
      expect(t.m110.pakete, hasLength(4));
      t.ende();
    });
  });

  test('Vergessen trennt und entfernt aus der Konfiguration', () async {
    final store = ConfigStore.forDirectory(temp);
    await store.mutate(
      (c) => c.copyWith(
        bluetoothDevices: [
          BluetoothDeviceConfig(
            id: fakeM110Id,
            name: 'Q199E00000',
            approvedAt: _start,
          ),
          BluetoothDeviceConfig(
            id: _zweiteId,
            name: 'Q199E00001',
            approvedAt: _start,
          ),
        ],
      ),
    );
    final m110 = FakeM110();
    final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
    final bus = EventBus();
    final geraetEreignisse = <Map<String, Object?>>[];
    bus.stream
        .where((e) => e.type == eventBluetoothDevice)
        .listen((e) => geraetEreignisse.add(e.data));
    final bridge = BluetoothBridge(
      store: store,
      log: log,
      events: bus,
      helper: fake,
    );
    addTearDown(bridge.close);

    expect(await bridge.connect(fakeM110Id), 1);
    await bridge.subscribe(fakeM110Id, 'ff00', 'ff03');
    final lease = await bridge.acquireLease(fakeM110Id);
    final wartet = expectLater(
      bridge.acquireLease(fakeM110Id),
      _scheitertMit(errorBluetoothDeviceUnknown),
    );
    // Die zweite Belegung soll schon in der Warteschlange stehen.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(await bridge.forget(fakeM110Id.toUpperCase()), isTrue);
    await wartet;
    expect(m110.verbunden, isFalse);
    expect(bridge.renewLease(fakeM110Id, lease.id), isFalse);
    expect(bridge.notifications(fakeM110Id), isEmpty);
    expect((await store.load()).bluetoothDevices.map((d) => d.id), [_zweiteId]);
    final summary = await bridge.summary();
    expect((summary['devices']! as List).map((d) => (d as Map)['id']), [
      _zweiteId,
    ]);
    await expectLater(
      bridge.connect(fakeM110Id),
      _scheitertMit(errorBluetoothDeviceUnknown),
    );
    await pumpEventQueue();
    expect(geraetEreignisse.last, {
      'id': fakeM110Id,
      'connected': false,
      'generation': 1,
      'reason': 'released',
    });

    // Ein zweites Mal gibt es nichts zu vergessen.
    expect(await bridge.forget(fakeM110Id), isFalse);

    // Wieder zugelassen: ein frischer Bedarf ohne das alte Abo, und die
    // Belegung hält und gibt wieder ordentlich frei.
    await bridge.approve(fakeM110Id);
    expect(await bridge.connect(fakeM110Id), 2);
    expect(m110.abonniert, isFalse);
    final neu = await bridge.acquireLease(fakeM110Id);
    expect(bridge.releaseLease(fakeM110Id, neu.id), isTrue);
    expect(m110.verbunden, isTrue);
  });

  test('isApproved: nur zugelassene Geräte, auch nicht während des '
      'Vergessens; berührt Bluetooth nicht', () async {
    final store = ConfigStore.forDirectory(temp);
    await store.mutate(
      (c) => c.copyWith(
        bluetoothDevices: [
          BluetoothDeviceConfig(
            id: fakeM110Id,
            name: 'Q199E00000',
            approvedAt: _start,
          ),
        ],
      ),
    );
    final fake = FakeBluetoothHelper(log: log, geraete: [FakeM110()]);
    final bus = EventBus();
    final bridge = BluetoothBridge(
      store: store,
      log: log,
      events: bus,
      helper: fake,
    );
    addTearDown(() async {
      await bridge.close();
      await bus.close();
    });

    expect(await bridge.isApproved(fakeM110Id), isTrue);
    expect(await bridge.isApproved(fakeM110Id.toUpperCase()), isTrue);
    expect(await bridge.isApproved(_zweiteId), isFalse);
    expect(await bridge.isApproved('kein-geraet'), isFalse);

    // Ab dem ersten Schritt des Vergessens gilt es nicht mehr als zugelassen,
    // auch solange es noch in der Datei steht.
    final vergessen = bridge.forget(fakeM110Id);
    final waehrend = bridge.isApproved(fakeM110Id);
    expect(await waehrend, isFalse);
    expect(await vergessen, isTrue);
    expect(await bridge.isApproved(fakeM110Id), isFalse);
    expect(fake.starts, 0);
  });

  test('17. Gerät: bluetooth_too_many_devices', () async {
    final store = ConfigStore.forDirectory(temp);
    var jetzt = _start;
    final fake = FakeBluetoothHelper(log: log);
    final bridge = BluetoothBridge(
      store: store,
      log: log,
      events: EventBus(),
      helper: fake,
      clock: () => jetzt,
    );
    addTearDown(bridge.close);
    String kennung(int i) =>
        '5e1a0c00-7d2b-4c3e-9f40-${i.toRadixString(16).padLeft(12, '0')}';

    for (var i = 0; i < 16; i++) {
      await bridge.approve(kennung(i), name: 'Gerät $i');
    }
    await expectLater(
      bridge.approve(kennung(16)),
      _scheitertMit(errorBluetoothTooManyDevices),
    );
    var config = await store.load();
    expect(config.bluetoothDevices, hasLength(16));
    expect(
      config.bluetoothDevices.map((d) => d.id),
      isNot(contains(kennung(16))),
    );

    // Ein schon zugelassenes Gerät lässt sich weiter umbenennen; der
    // Zeitpunkt der Zulassung bleibt.
    jetzt = _start.add(const Duration(days: 3));
    final umbenannt = await bridge.approve(kennung(3), name: 'Waage');
    expect(umbenannt['name'], 'Waage');
    expect(umbenannt['approvedAt'], _startIso);

    // Nach dem Vergessen eines Geräts passt das nächste hinein.
    expect(await bridge.forget(kennung(0)), isTrue);
    await bridge.approve(kennung(16));
    config = await store.load();
    expect(config.bluetoothDevices, hasLength(16));
    expect(config.bluetoothDevices.last.id, kennung(16));

    // Zulassen und Vergessen berühren Bluetooth nicht.
    expect(fake.starts, 0);
  });

  test('Zulassen: Name aus dem Aufruf, sonst aus der letzten Suche, sonst '
      'die Kennung', () async {
    final store = ConfigStore.forDirectory(temp);
    var jetzt = _start;
    final fake = FakeBluetoothHelper(
      log: log,
      geraete: [
        FakeM110(),
        FakeM110(id: _zweiteId, name: 'Q199E00001', nameErstSpaeter: true),
      ],
    );
    final bridge = BluetoothBridge(
      store: store,
      log: log,
      events: EventBus(),
      helper: fake,
      clock: () => jetzt,
    );
    addTearDown(bridge.close);

    final funde = await bridge.scan(duration: const Duration(seconds: 1));
    expect(funde.map((f) => f['id']), [fakeM110Id, _zweiteId]);
    expect(funde.map((f) => f['name']), ['Q199E00000', 'Q199E00001']);
    expect(funde.map((f) => f['approved']), [false, false]);

    expect(await bridge.approve(fakeM110Id.toUpperCase()), {
      'id': fakeM110Id,
      'name': 'Q199E00000',
      'approvedAt': _startIso,
      'connected': false,
      'generation': 0,
    });
    final benannt = await bridge.approve(
      _zweiteId,
      name: '  Etiketten Lager  ',
    );
    expect(benannt['name'], 'Etiketten Lager');
    final namenlos = await bridge.approve(_dritteId);
    expect(namenlos['name'], _dritteId);

    // Erneut zulassen: neuer Name, alter Zeitpunkt.
    jetzt = _start.add(const Duration(days: 3));
    final umbenannt = await bridge.approve(fakeM110Id, name: 'Etiketten 1');
    expect(umbenannt['name'], 'Etiketten 1');
    expect(umbenannt['approvedAt'], _startIso);
    // Ohne Namen: der Name aus der Suche, sonst bleibt der gespeicherte.
    final gefunden = await bridge.approve(_zweiteId);
    expect(gefunden['name'], 'Q199E00001');
    await bridge.approve(_dritteId, name: 'Waage');
    final bleibt = await bridge.approve(_dritteId);
    expect(bleibt['name'], 'Waage');

    final gespeichert = (await store.load()).bluetoothDevices;
    expect(gespeichert.map((d) => d.name), [
      'Etiketten 1',
      'Q199E00001',
      'Waage',
    ]);
    expect(gespeichert.map((d) => d.approvedAt), everyElement(_start));
  });

  test('Suche: 1–10 s, gleichzeitige Suchen teilen sich eine, je Gerät ein '
      'Eintrag', () {
    fakeAsync((async) {
      final t = _Aufbau(
        async,
        temp,
        log,
        geraete: [
          FakeM110(),
          FakeM110(
            id: _zweiteId,
            name: 'Q199E00001',
            rssi: -71,
            nameErstSpaeter: true,
          ),
        ],
      );
      List<Object?> dauern() => [
        for (final b in t.fake.befehle)
          if (b.op == HelperOp.scan) b.args['ms'],
      ];

      final erste = _verfolge(t.bridge.scan());
      final zweite = _verfolge(
        t.bridge.scan(duration: const Duration(seconds: 9)),
      );
      async.elapse(const Duration(milliseconds: 3999));
      expect(erste.fertig, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(erste.wert, [
        {
          'id': fakeM110Id,
          'name': 'Q199E00000',
          'rssi': -58,
          'services': [_ff00],
          'approved': true,
        },
        {
          'id': _zweiteId,
          'name': 'Q199E00001',
          'rssi': -71,
          'services': [_ff00],
          'approved': false,
        },
      ]);
      expect(zweite.wert, erste.wert);
      expect(dauern(), [4000]);

      // Kürzer als 1 s wird 1 s, länger als 10 s wird 10 s.
      final kurz = _verfolge(t.bridge.scan(duration: Duration.zero));
      async.elapse(const Duration(seconds: 1));
      expect(kurz.fertig, isTrue);
      final lang = _verfolge(
        t.bridge.scan(duration: const Duration(minutes: 1)),
      );
      async.elapse(const Duration(seconds: 10));
      expect(lang.fertig, isTrue);
      expect(dauern(), [4000, 1000, 10000]);

      // Suchen verbindet nichts.
      expect(t.m110.verbindungen, 0);
      t.ende();
    });
  });

  test('Fehlercodes: jeder Code mit deutschem Text, Funkzustand und '
      'Gerätefehler übersetzt', () {
    expect(bluetoothErrorMessages.keys.toSet(), {
      'bluetooth_unsupported',
      'bluetooth_unauthorized',
      'bluetooth_off',
      'bluetooth_unavailable',
      'bluetooth_device_unknown',
      'bluetooth_device_not_found',
      'bluetooth_unreachable',
      'bluetooth_blocked',
      'bluetooth_characteristic_unknown',
      'bluetooth_operation_unsupported',
      'bluetooth_lease_required',
      'bluetooth_busy',
      'bluetooth_write_too_long',
      'bluetooth_write_failed',
      'bluetooth_disconnected',
      'bluetooth_too_many_devices',
    });
    for (final text in bluetoothErrorMessages.values) {
      expect(text, matches(RegExp(r'^[A-ZÄÖÜ].*\.$')));
    }
    expect(
      bluetoothErrorMessages[errorBluetoothUnauthorized],
      'Kasseneck Connect darf Bluetooth nicht verwenden – bitte in den '
      'Systemeinstellungen unter Datenschutz & Sicherheit → Bluetooth '
      'erlauben.',
    );
    expect(
      bluetoothErrorMessages[errorBluetoothOff],
      'Bluetooth ist am Mac ausgeschaltet.',
    );
    expect(
      bluetoothErrorMessages[errorBluetoothUnreachable],
      'Nicht erreichbar – vielleicht mit einem anderen Gerät verbunden.',
    );

    fakeAsync((async) {
      // Das zweite Gerät ist zugelassen, aber diesem Mac unbekannt.
      final t = _Aufbau(
        async,
        temp,
        log,
        zugelassen: const {fakeM110Id: 'Q199E00000', _zweiteId: 'Q199E00001'},
      );
      t.fake.setzeZustand('poweredOff');
      final aus = t.fehler(t.bridge.connect(fakeM110Id));
      expect(aus.code, errorBluetoothOff);
      expect(aus.message, 'Bluetooth ist am Mac ausgeschaltet.');

      t.fake.setzeZustand('unauthorized');
      async.flushMicrotasks();
      expect(
        t.fehler(t.bridge.connect(fakeM110Id)).code,
        errorBluetoothUnauthorized,
      );
      expect(t.fehler(t.bridge.scan()).code, errorBluetoothUnauthorized);

      t.fake.setzeZustand('poweredOn');
      async.flushMicrotasks();
      expect(
        t.fehler(t.bridge.connect(_zweiteId)).code,
        errorBluetoothDeviceNotFound,
      );

      t.m110.vonAnderemGeraetGehalten = true;
      final weg = _verfolge(t.bridge.connect(fakeM110Id));
      async.elapse(const Duration(seconds: 10));
      expect(weg.code, errorBluetoothUnreachable);
      t.m110.vonAnderemGeraetGehalten = false;

      t.verbinden();
      expect(
        t.fehler(t.bridge.read(fakeM110Id, 'ff00', 'ff09')).code,
        errorBluetoothCharacteristicUnknown,
      );
      expect(
        t.fehler(t.bridge.read(fakeM110Id, 'ff00', 'ff02')).code,
        errorBluetoothOperationUnsupported,
      );
      final lease = t.belegen();
      final falsch = t.fehler(
        t.bridge.write(
          fakeM110Id,
          'ff00',
          'ff03',
          [Uint8List(2)],
          withResponse: true,
          lease: lease.id,
        ),
      );
      expect(falsch.code, errorBluetoothOperationUnsupported);
      expect(falsch.detail, {'written': 0});

      // Eine zweite Belegung, die nicht drankommt.
      final belegt = _verfolge(
        t.bridge.acquireLease(fakeM110Id, wait: const Duration(seconds: 2)),
      );
      for (var i = 0; i < 2; i++) {
        async.elapse(const Duration(seconds: 1));
        expect(t.bridge.renewLease(fakeM110Id, lease.id), isTrue);
      }
      expect(belegt.code, errorBluetoothBusy);

      // Unbrauchbare UUID: Sache der Route (bad_request).
      final kaputt = _verfolge(t.bridge.read(fakeM110Id, 'xyz', 'ff01'));
      async.flushMicrotasks();
      expect(kaputt.fehler, isA<FormatException>());
      t.ende();
    });
  });

  test('kaputte Antwort des Hilfsprogramms: bluetooth_unavailable, Agent '
      'läuft weiter', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log, huelle: _KaputteAntworten.new);
      t.verbinden();
      final lesen = t.fehler(t.bridge.read(fakeM110Id, 'ff00', 'ff01'));
      expect(lesen.code, errorBluetoothUnavailable);
      expect(lesen.message, bluetoothErrorMessages[errorBluetoothUnavailable]);
      expect(
        t.fehler(t.bridge.gatt(fakeM110Id)).code,
        errorBluetoothUnavailable,
      );
      expect(logText(), contains('unlesbare Antwort'));

      // Alles andere geht weiter.
      t.abonnieren();
      final lease = t.belegen();
      expect(t.schreiben(lease, [_paket(1)]), 1);
      expect(t.meldungen.last, '1#2 01 01');
      t.ende();
    });
  });

  test('ohne Hilfsprogramm: bluetooth_unsupported; summary berührt '
      'Bluetooth nie', () {
    fakeAsync((async) {
      _zulassen(temp, const {fakeM110Id: 'Q199E00000'});
      final bridge = BluetoothBridge(
        store: _SofortLeser(temp),
        log: log,
        events: EventBus(),
        helper: const UnsupportedBluetoothHelper(),
      );
      expect(bridge.available, isFalse);
      expect(bridge.state, 'unsupported');
      final summary = _verfolge(bridge.summary());
      async.flushMicrotasks();
      expect(summary.wert, {
        'state': 'unsupported',
        'devices': [
          {
            'id': fakeM110Id,
            'name': 'Q199E00000',
            'approvedAt': _startIso,
            'connected': false,
            'generation': 0,
          },
        ],
      });
      final aufrufe = <String, Future<Object?>>{
        'scan': bridge.scan(),
        'approve': bridge.approve(_zweiteId),
        'connect': bridge.connect(fakeM110Id),
        'gatt': bridge.gatt(fakeM110Id),
        'read': bridge.read(fakeM110Id, 'ff00', 'ff01'),
        'subscribe': bridge.subscribe(fakeM110Id, 'ff00', 'ff03'),
        'acquireLease': bridge.acquireLease(fakeM110Id),
      };
      final ausgaenge = {
        for (final e in aufrufe.entries) e.key: _verfolge(e.value),
      };
      async.flushMicrotasks();
      for (final e in ausgaenge.entries) {
        expect(e.value.code, errorBluetoothUnsupported, reason: e.key);
      }
    });

    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      expect(t.bridge.available, isTrue);
      expect(t.ok(t.bridge.summary()), {
        'state': 'unknown',
        'devices': [
          {
            'id': fakeM110Id,
            'name': 'Q199E00000',
            'approvedAt': _startIso,
            'connected': false,
            'generation': 0,
          },
        ],
      });
      expect(t.fake.starts, 0);

      t.verbinden();
      final summary = t.ok(t.bridge.summary())!;
      expect(summary['state'], 'poweredOn');
      expect((summary['devices']! as List).single, {
        'id': fakeM110Id,
        'name': 'Q199E00000',
        'approvedAt': _startIso,
        'connected': true,
        'generation': 1,
      });
      t.ende();
    });
  });

  test('Log enthält keine Nutzdaten', () {
    fakeAsync((async) {
      final t = _Aufbau(async, temp, log);
      t.verbinden();
      t.abonnieren();
      final lease = t.belegen();

      // Ein Etikett trägt einen Gutscheincode.
      final code = utf8.encode('GUTSCHEIN-7Q4K-93XZ-ABCD');
      final pakete = <List<int>>[
        code,
        [...code, ...List<int>.filled(100, 0x42)],
        List<int>.generate(180, (i) => i),
      ];
      expect(t.schreiben(lease, pakete), 3);
      expect(t.schreiben(lease, [code.sublist(0, 20)], withResponse: false), 1);
      async.elapse(const Duration(seconds: 3));

      final text = logText();
      final summe = pakete.fold<int>(0, (s, paket) => s + paket.length);
      expect(text, contains(fakeM110Id));
      expect(text, contains('3 Paket(e), $summe Byte mit Antwort'));
      expect(text, contains('1 Paket(e), 20 Byte ohne Antwort'));
      for (final paket in [...pakete, code.sublist(0, 20)]) {
        expect(text, isNot(contains(base64Encode(paket))));
        expect(text, isNot(contains(_hex(paket))));
        expect(text, isNot(contains(_hex(paket).replaceAll(' ', ''))));
      }
      expect(text, isNot(contains('GUTSCHEIN')));
      expect(text, isNot(contains('7Q4K')));
      expect(text, isNot(contains(lease.id)));
      t.ende();
    });
  });
}
