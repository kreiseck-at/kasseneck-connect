import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:kasseneck_connect/src/bluetooth/helper.dart';
import 'package:kasseneck_connect/src/bluetooth/protocol.dart';
import 'package:kasseneck_connect/src/log/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_bluetooth.dart';

/// Ausgang eines Aufrufs, ohne `await` – in `fakeAsync` läuft die Zeit nur
/// auf Zuruf.
class _Ausgang {
  Map<String, Object?>? wert;
  Object? fehler;

  bool get fertig => wert != null || fehler != null;

  String? get code => switch (fehler) {
    BluetoothFailure(:final code) => code,
    _ => null,
  };
}

_Ausgang _verfolge(Future<Map<String, Object?>> aufruf) {
  final ausgang = _Ausgang();
  unawaited(
    aufruf.then<void>(
      (wert) => ausgang.wert = wert,
      onError: (Object fehler) => ausgang.fehler = fehler,
    ),
  );
  return ausgang;
}

/// Startet nur Prozesse im Speicher und merkt sie sich.
class _Starter {
  final List<FakeHelperProcess> prozesse = <FakeHelperProcess>[];

  Future<Process> start(String executable, List<String> arguments) async {
    final prozess = FakeHelperProcess(100 + prozesse.length);
    prozesse.add(prozess);
    return prozess;
  }
}

void _stoppen(BluetoothHelper helper, FakeAsync async) {
  unawaited(helper.stop());
  async.elapse(const Duration(seconds: 5));
}

/// Bytes einer Meldung als Hex (`01 01`).
String _hex(HelperEvent ereignis) => base64Decode(
  ereignis.data['data']! as String,
).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

Map<String, Object?> _merkmal(
  String characteristic, [
  String service = 'ff00',
]) => {
  'device': fakeM110Id,
  'service': service,
  'characteristic': characteristic,
};

Map<String, Object?> _schreiben(List<int> bytes, {bool mitAntwort = true}) => {
  ..._merkmal('ff02'),
  'data': base64Encode(bytes),
  'withResponse': mitAntwort,
};

void main() {
  late Directory temp;
  late AgentLog log;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-bt-helper-');
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String logText() => log.file.existsSync() ? log.file.readAsStringSync() : '';

  test('kein Start ohne Aufruf', () {
    fakeAsync((async) {
      final starter = _Starter();
      final helper = ProcessBluetoothHelper(
        executable: bluetoothHelperName,
        log: log,
        start: starter.start,
      );
      final ereignisse = <HelperEvent>[];
      helper.events.listen(ereignisse.add);
      async.elapse(const Duration(minutes: 5));
      expect(starter.prozesse, isEmpty);
      expect(helper.state, 'unknown');
      expect(ereignisse, isEmpty);

      // Auch der Weg über die Plattform legt den Helfer nur an.
      final bin = Directory(p.join(temp.path, 'bin'))..createSync();
      File(p.join(bin.path, bluetoothHelperName)).writeAsStringSync('');
      final plattform = platformBluetoothHelper(
        log,
        environment: const <String, String>{},
        operatingSystem: 'macos',
        executable: p.join(bin.path, 'kasseneck-connect'),
        start: starter.start,
      );
      expect(plattform, isA<ProcessBluetoothHelper>());
      async.elapse(const Duration(minutes: 5));
      expect(starter.prozesse, isEmpty);
      expect(plattform.state, 'unknown');
    });
  });

  test('Antworten finden über die id zum Aufruf', () {
    fakeAsync((async) {
      final starter = _Starter();
      final helper = ProcessBluetoothHelper(
        executable: bluetoothHelperName,
        log: log,
        start: starter.start,
      );
      final zustand = _verfolge(helper.call(HelperOp.state));
      final gatt = _verfolge(
        helper.call(HelperOp.gatt, {'device': fakeM110Id}),
      );
      final lesen = _verfolge(helper.call(HelperOp.read, _merkmal('ff01')));
      expect(helper.state, 'starting');
      async.flushMicrotasks();

      final prozess = starter.prozesse.single;
      expect(prozess.befehle.map((b) => b.op), ['state', 'gatt', 'read']);
      expect(prozess.befehle.map((b) => b.id).toSet(), hasLength(3));
      final [anZustand, anGatt, anLesen] = prozess.befehle;
      expect(anGatt.args, {'device': fakeM110Id});

      // Antworten in anderer Reihenfolge, dazwischen eine fremde id.
      prozess
        ..sende(const HelperEvent('state', {'state': 'poweredOn'}))
        ..sende(HelperResponse(anGatt.id, const {'services': <Object?>[]}))
        ..sende(const HelperResponse(999999, {'data': 'AQE='}))
        ..sende(
          HelperResponse(
            anLesen.id,
            const {},
            error: const HelperError(
              'not_connected',
              'peripheral is not connected',
            ),
          ),
        )
        ..sende(HelperResponse(anZustand.id, const {'state': 'poweredOn'}));
      async.flushMicrotasks();

      expect(gatt.wert, {'services': <Object?>[]});
      expect(zustand.wert, {'state': 'poweredOn'});
      expect(lesen.code, 'not_connected');
      expect(
        (lesen.fehler! as BluetoothFailure).message,
        'peripheral is not connected',
      );
      expect(helper.state, 'poweredOn');
      expect(starter.prozesse, hasLength(1));
      _stoppen(helper, async);
    });
  });

  test('stirbt der Helfer, enden offene Aufrufe mit bluetooth_unavailable '
      'und er startet neu', () {
    fakeAsync((async) {
      final m110 = FakeM110();
      final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
      final ereignisse = <HelperEvent>[];
      fake.events.listen(ereignisse.add);
      final verbinden = _verfolge(
        fake.call(HelperOp.connect, {'device': m110.id}),
      );
      async.flushMicrotasks();
      expect(verbinden.wert, isEmpty);
      final suche = _verfolge(fake.call(HelperOp.scan, {'ms': 10000}));
      async.flushMicrotasks();
      expect(suche.fertig, isFalse);
      ereignisse.clear();

      fake.abstuerzen();
      async.flushMicrotasks();
      expect(suche.code, 'bluetooth_unavailable');
      expect(fake.state, 'helper_restarting');
      // Wer verbunden war, erfährt es – wie beim Verlust der Verbindung.
      expect(ereignisse.map((e) => e.event), ['state', 'disconnected']);
      expect(ereignisse.first.data, {'state': 'helper_restarting'});
      expect(ereignisse.last.data['device'], m110.id);
      expect(logText(), contains('Bluetooth-Hilfsprogramm'));

      // Ohne Aufruf kein Neustart, auch nach der Pause nicht.
      async.elapse(const Duration(minutes: 2));
      expect(fake.starts, 1);
      expect(
        async.periodicTimerCount,
        0,
        reason: 'kein Herzschlag ohne Prozess',
      );

      // Der nächste Aufruf startet ihn neu.
      final zustand = _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      expect(fake.starts, 2);
      expect(zustand.wert, {'state': 'poweredOn'});
      expect(fake.state, 'poweredOn');
      _stoppen(fake, async);
    });
  });

  test('Herzschlag ohne Antwort beendet und startet neu', () {
    fakeAsync((async) {
      final fake = FakeBluetoothHelper(log: log);
      final erster = _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      expect(erster.wert, {'state': 'poweredOn'});

      // Gesund: alle 5 s ein ping, beantwortet, der Prozess bleibt.
      async.elapse(const Duration(seconds: 60));
      expect(fake.pings, 12);
      expect(fake.prozesse.single.killedWith, isNull);

      fake.haengen();
      final offen = _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
      async.elapse(const Duration(seconds: 5));
      expect(fake.pings, 13);
      async.elapse(const Duration(milliseconds: 2999));
      expect(fake.prozesse.single.killedWith, isNull);
      expect(offen.fertig, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(fake.prozesse.single.killedWith, ProcessSignal.sigkill);
      expect(offen.code, 'bluetooth_unavailable');
      expect(fake.state, 'helper_restarting');
      expect(logText(), contains('Herzschlag'));

      // Kein Herzschlag mehr an den beendeten Prozess.
      async.elapse(const Duration(seconds: 30));
      expect(fake.pings, 13);
      expect(async.periodicTimerCount, 0);

      final danach = _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      expect(fake.starts, 2);
      expect(danach.wert, {'state': 'poweredOn'});
      _stoppen(fake, async);
    });
  });

  test('stirbt der Helfer sofort wieder, wächst die Pause bis 30 s', () {
    fakeAsync((async) {
      final fake = FakeBluetoothHelper(log: log)..stirbtBeimStart = true;
      final ausgaenge = <_Ausgang>[];
      void aufrufen() => ausgaenge.add(_verfolge(fake.call(HelperOp.state)));

      aufrufen();
      async.flushMicrotasks();
      expect(fake.starts, 1);
      expect(ausgaenge.last.code, 'bluetooth_unavailable');
      expect(fake.state, 'helper_restarting');

      // Kurze Pausen wartet ein Aufruf ab; gestartet wird erst danach.
      var starts = 1;
      for (final sekunden in [1, 2, 5, 10]) {
        aufrufen();
        async.elapse(
          Duration(seconds: sekunden) - const Duration(milliseconds: 1),
        );
        expect(fake.starts, starts, reason: 'vor Ablauf von $sekunden s');
        expect(ausgaenge.last.fertig, isFalse);
        expect(fake.state, 'helper_restarting');
        async.elapse(const Duration(milliseconds: 1));
        expect(fake.starts, ++starts, reason: 'nach $sekunden s');
        expect(ausgaenge.last.code, 'bluetooth_unavailable');
      }

      // Ab jetzt 30 s (Deckel): länger, als ein Aufruf warten darf – er
      // scheitert sofort, und es startet nichts.
      for (var runde = 0; runde < 2; runde++) {
        aufrufen();
        async.flushMicrotasks();
        expect(ausgaenge.last.code, 'bluetooth_unavailable');
        expect(fake.starts, starts);
        async.elapse(const Duration(seconds: 29, milliseconds: 999));
        aufrufen();
        async.flushMicrotasks();
        expect(ausgaenge.last.code, 'bluetooth_unavailable');
        expect(fake.starts, starts, reason: 'Pause von 30 s noch nicht um');
        expect(fake.state, 'helper_restarting');
        async.elapse(const Duration(milliseconds: 1));
        aufrufen();
        async.flushMicrotasks();
        expect(fake.starts, ++starts, reason: 'Pause von 30 s um');
      }
      expect(logText(), contains('30 s'));
    });
  });

  test('nach 60 s ruhigem Lauf beginnt die Pause wieder bei 1 s', () {
    fakeAsync((async) {
      final fake = FakeBluetoothHelper(log: log);
      void aufrufen() => _verfolge(fake.call(HelperOp.state));
      void abstuerzen() {
        fake.abstuerzen();
        async.flushMicrotasks();
      }

      aufrufen();
      async.flushMicrotasks();
      abstuerzen(); // Pause 1 s
      aufrufen();
      async.elapse(const Duration(seconds: 1));
      expect(fake.starts, 2);
      abstuerzen(); // Pause 2 s
      aufrufen();
      async.elapse(const Duration(seconds: 2));
      expect(fake.starts, 3);
      async.elapse(const Duration(seconds: 59));
      abstuerzen(); // nach 59 s Lauf: Pause 5 s
      aufrufen();
      async.elapse(const Duration(milliseconds: 4999));
      expect(fake.starts, 3);
      async.elapse(const Duration(milliseconds: 1));
      expect(fake.starts, 4);

      async.elapse(const Duration(seconds: 60));
      abstuerzen(); // nach 60 s ruhigem Lauf: wieder 1 s
      aufrufen();
      async.elapse(const Duration(milliseconds: 999));
      expect(fake.starts, 4);
      async.elapse(const Duration(milliseconds: 1));
      expect(fake.starts, 5);
      _stoppen(fake, async);
    });
  });

  test('Freigabe entzogen: Zustand unauthorized, Code durchgereicht, '
      'kein Neustart', () {
    fakeAsync((async) {
      final fake = FakeBluetoothHelper(log: log, zustand: 'unauthorized');
      final suche = _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
      async.flushMicrotasks();
      expect(suche.code, 'unauthorized');
      expect(fake.state, 'unauthorized');
      async.elapse(const Duration(minutes: 2));
      expect(fake.starts, 1);
      expect(fake.state, 'unauthorized');
      _stoppen(fake, async);
    });
  });

  group('Freigabe in den Systemeinstellungen erteilt', () {
    test('die nächste Suche nach der Drosselzeit startet neu und sieht '
        'poweredOn; innerhalb der Drosselzeit kein zweiter Neustart', () {
      fakeAsync((async) {
        final fake = FakeBluetoothHelper(log: log, zustand: 'unauthorized');
        final erste = _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
        async.flushMicrotasks();
        expect(erste.code, 'unauthorized');
        fake.aendereFreigabe('poweredOn');

        // Zu früh: der Prozess läuft weiter, die Freigabe gilt noch nicht.
        async.elapse(const Duration(seconds: 9));
        final zuFrueh = _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
        async.flushMicrotasks();
        expect(zuFrueh.code, 'unauthorized');
        expect(fake.starts, 1);

        async.elapse(const Duration(seconds: 1));
        final suche = _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
        async.elapse(const Duration(seconds: 2));
        expect(suche.fehler, isNull);
        expect(fake.starts, 2);
        expect(fake.state, 'poweredOn');
        expect(fake.prozesse.first.killedWith, isNotNull);
        _stoppen(fake, async);
      });
    });

    test('ein gewollter Neustart zählt nicht als Absturz: der nächste echte '
        'Absturz wartet nur 1 s', () {
      fakeAsync((async) {
        final fake = FakeBluetoothHelper(log: log, zustand: 'unauthorized');
        _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
        async.flushMicrotasks();
        fake.aendereFreigabe('poweredOn');
        async.elapse(const Duration(seconds: 10));
        _verfolge(fake.call(HelperOp.state));
        async.flushMicrotasks();
        expect(fake.starts, 2);

        fake.abstuerzen();
        async.flushMicrotasks();
        _verfolge(fake.call(HelperOp.state));
        async.elapse(const Duration(milliseconds: 999));
        expect(fake.starts, 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(fake.starts, 3);
        _stoppen(fake, async);
      });
    });

    test('refresh startet bei unauthorized neu, aber nur ein laufendes '
        'Hilfsprogramm und nur gedrosselt', () {
      fakeAsync((async) {
        final fake = FakeBluetoothHelper(log: log, zustand: 'unauthorized');
        // Ohne laufendes Hilfsprogramm startet refresh nichts.
        unawaited(fake.refresh());
        async.elapse(const Duration(seconds: 30));
        expect(fake.starts, 0);

        _verfolge(fake.call(HelperOp.state));
        async.flushMicrotasks();
        expect(fake.state, 'unauthorized');
        fake.aendereFreigabe('poweredOn');

        unawaited(fake.refresh());
        async.elapse(const Duration(seconds: 5));
        expect(fake.starts, 1);
        expect(fake.state, 'unauthorized');

        async.elapse(const Duration(seconds: 5));
        unawaited(fake.refresh());
        async.elapse(const Duration(seconds: 1));
        expect(fake.starts, 2);
        expect(fake.state, 'poweredOn');
        _stoppen(fake, async);
      });
    });

    test('bei poweredOff gibt es keinen Neustart', () {
      fakeAsync((async) {
        final fake = FakeBluetoothHelper(log: log, zustand: 'poweredOff');
        _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
        async.elapse(const Duration(seconds: 20));
        unawaited(fake.refresh());
        _verfolge(fake.call(HelperOp.state));
        async.elapse(const Duration(seconds: 20));
        expect(fake.starts, 1);
        _stoppen(fake, async);
      });
    });
  });

  test('kaputte Zeile wird verworfen, der nächste Aufruf klappt', () {
    fakeAsync((async) {
      final fake = FakeBluetoothHelper(log: log);
      final erster = _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      expect(erster.wert, {'state': 'poweredOn'});

      fake
        ..sendeZeile('{"id":1') // halbe Zeile
        ..sendeZeile('Segmentation fault AQIDBA==')
        ..sendeBytes(const [0xff, 0xfe, 0x0a]) // kein UTF-8
        ..sendeZeile('[]');
      async.flushMicrotasks();

      final zweiter = _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      expect(zweiter.wert, {'state': 'poweredOn'});
      expect(fake.starts, 1);
      final text = logText();
      expect(RegExp('unlesbare Zeile').allMatches(text), hasLength(4));
      // Nur die Länge, nie der Inhalt.
      expect(text, isNot(contains('Segmentation')));
      expect(text, isNot(contains('AQIDBA')));
      _stoppen(fake, async);
    });
  });

  test('ohne Antwort nach 15 s bluetooth_unavailable, die späte Antwort '
      'wird verworfen', () {
    fakeAsync((async) {
      // Wie beim ersten Freigabe-Dialog: Befehle warten im Hilfsprogramm.
      final fake = FakeBluetoothHelper(log: log, zustand: 'unknown');
      final suche = _verfolge(fake.call(HelperOp.scan, {'ms': 1000}));
      async.elapse(const Duration(seconds: 14, milliseconds: 999));
      expect(suche.fertig, isFalse);
      expect(fake.state, 'unknown');
      async.elapse(const Duration(milliseconds: 1));
      expect(suche.code, 'bluetooth_unavailable');
      expect(
        (suche.fehler! as BluetoothFailure).message,
        contains('nicht rechtzeitig'),
      );
      // ping wartet nicht: der Herzschlag hält den Prozess am Leben.
      expect(fake.starts, 1);
      expect(fake.prozesse.single.killedWith, isNull);

      // Freigabe erteilt: die Antwort auf den alten Aufruf kennt niemand mehr.
      fake.setzeZustand('poweredOn');
      async.elapse(const Duration(seconds: 2));
      expect(fake.state, 'poweredOn');
      final danach = _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      expect(danach.wert, {'state': 'poweredOn'});
      expect(suche.code, 'bluetooth_unavailable');
      expect(fake.starts, 1);
      _stoppen(fake, async);
    });
  });

  test('stop schließt stdin, wartet kurz und beendet sonst hart', () {
    fakeAsync((async) {
      // Das Hilfsprogramm endet bei EOF von selbst.
      final fake = FakeBluetoothHelper(log: log);
      _verfolge(fake.call(HelperOp.state));
      async.flushMicrotasks();
      var gestoppt = false;
      unawaited(fake.stop().then((_) => gestoppt = true));
      async.flushMicrotasks();
      expect(fake.prozesse.single.stdinGeschlossen, isTrue);
      expect(fake.prozesse.single.killedWith, isNull);
      expect(gestoppt, isTrue);
      expect(fake.laeuft, isFalse);
      expect(fake.state, 'unknown');
      final danach = _verfolge(fake.call(HelperOp.state));
      async.elapse(const Duration(seconds: 5));
      expect(danach.code, 'bluetooth_unavailable');
      expect(fake.starts, 1);

      // Ein Prozess, der EOF übergeht, wird nach kurzer Wartezeit beendet.
      final starter = _Starter();
      final helper = ProcessBluetoothHelper(
        executable: bluetoothHelperName,
        log: log,
        start: starter.start,
      );
      final offen = _verfolge(helper.call(HelperOp.state));
      async.flushMicrotasks();
      var fertig = false;
      unawaited(helper.stop().then((_) => fertig = true));
      async.flushMicrotasks();
      final prozess = starter.prozesse.single;
      expect(prozess.stdinGeschlossen, isTrue);
      expect(prozess.killedWith, isNull);
      expect(fertig, isFalse);
      async.elapse(const Duration(seconds: 5));
      expect(prozess.killedWith, ProcessSignal.sigkill);
      expect(fertig, isTrue);
      expect(offen.code, 'bluetooth_unavailable');
    });
  });

  test('Notizen auf stderr landen im Log', () {
    fakeAsync((async) {
      final starter = _Starter();
      final helper = ProcessBluetoothHelper(
        executable: bluetoothHelperName,
        log: log,
        start: starter.start,
      );
      _verfolge(helper.call(HelperOp.state));
      async.flushMicrotasks();
      starter.prozesse.single.notiz(
        'kasseneck-bluetooth: Merkmale von FF00 nicht gelesen',
      );
      async.flushMicrotasks();
      expect(logText(), contains('Merkmale von FF00 nicht gelesen'));
      _stoppen(helper, async);
    });
  });

  test('Unsupported meldet bluetooth_unsupported', () async {
    const helper = UnsupportedBluetoothHelper();
    expect(helper.state, 'unsupported');
    await expectLater(
      helper.call(HelperOp.scan, {'ms': 1000}),
      throwsA(
        isA<BluetoothFailure>().having(
          (f) => f.code,
          'code',
          'bluetooth_unsupported',
        ),
      ),
    );
    expect(await helper.events.isEmpty, isTrue);
    await helper.stop();
  });

  group('platformBluetoothHelper', () {
    late String binary;

    setUp(() {
      final ordner = Directory(
        p.join(temp.path, 'Kasseneck Connect.app', 'Contents', 'MacOS'),
      )..createSync(recursive: true);
      binary = p.join(ordner.path, 'kasseneck-connect');
    });

    String nebenDerBinary() => p.join(p.dirname(binary), 'kasseneck-bluetooth');

    test('macOS mit Hilfsprogramm neben der Binary', () {
      File(nebenDerBinary()).writeAsStringSync('');
      final helper = platformBluetoothHelper(
        log,
        environment: const <String, String>{},
        operatingSystem: 'macos',
        executable: binary,
      );
      expect(
        helper,
        isA<ProcessBluetoothHelper>().having(
          (h) => h.executable,
          'executable',
          nebenDerBinary(),
        ),
      );
    });

    test('macOS ohne Hilfsprogramm: unsupported', () {
      final helper = platformBluetoothHelper(
        log,
        environment: const <String, String>{},
        operatingSystem: 'macos',
        executable: binary,
      );
      expect(helper, isA<UnsupportedBluetoothHelper>());
      expect(helper.state, 'unsupported');
    });

    test('Windows und Linux: unsupported, auch mit Hilfsprogramm', () {
      File(nebenDerBinary()).writeAsStringSync('');
      for (final os in ['windows', 'linux']) {
        final helper = platformBluetoothHelper(
          log,
          environment: {'KASSENECK_CONNECT_BT_HELPER': nebenDerBinary()},
          operatingSystem: os,
          executable: binary,
        );
        expect(helper, isA<UnsupportedBluetoothHelper>(), reason: os);
      }
    });

    test('KASSENECK_CONNECT_BT_HELPER zeigt auf ein anderes Hilfsprogramm', () {
      final anderes = File(p.join(temp.path, 'mein-helfer'))
        ..writeAsStringSync('');
      final helper = platformBluetoothHelper(
        log,
        environment: {'KASSENECK_CONNECT_BT_HELPER': anderes.path},
        operatingSystem: 'macos',
        executable: binary,
      );
      expect(
        helper,
        isA<ProcessBluetoothHelper>().having(
          (h) => h.executable,
          'executable',
          anderes.path,
        ),
      );

      final insLeere = platformBluetoothHelper(
        log,
        environment: {
          'KASSENECK_CONNECT_BT_HELPER': p.join(temp.path, 'fehlt'),
        },
        operatingSystem: 'macos',
        executable: binary,
      );
      expect(insLeere, isA<UnsupportedBluetoothHelper>());
      expect(logText(), contains('KASSENECK_CONNECT_BT_HELPER'));
    });
  });

  group('Attrappe (FakeM110)', () {
    test('connected vor der Antwort, 02 b6 00 nach dem Abo, 01 01 je Paket, '
        '1a 0f 0c nach 2,5 s', () {
      fakeAsync((async) {
        final m110 = FakeM110();
        final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
        final ablauf = <String>[];
        final ereignisse = <HelperEvent>[];
        fake.events.listen((e) {
          ereignisse.add(e);
          ablauf.add(e.event == 'notification' ? _hex(e) : e.event);
        });
        unawaited(
          fake
              .call(HelperOp.connect, {'device': m110.id})
              .then((_) => ablauf.add('verbunden')),
        );
        async.flushMicrotasks();
        // Erst der eigene Startzustand, dann der des Hilfsprogramms.
        expect(ablauf, ['state', 'state', 'connected', 'verbunden']);
        expect(ereignisse[0].data, {'state': 'starting'});
        expect(ereignisse[1].data, {'state': 'poweredOn'});
        expect(ereignisse[2].data, {
          'device': fakeM110Id,
          'maxWriteWithResponse': 512,
          'maxWriteWithoutResponse': 20,
        });

        ablauf.clear();
        _verfolge(fake.call(HelperOp.subscribe, _merkmal('ff03')));
        async.flushMicrotasks();
        expect(ablauf, ['02 b6 00']);
        expect(
          ereignisse.last.data['characteristic'],
          '0000ff03-0000-1000-8000-00805f9b34fb',
        );

        ablauf.clear();
        final antworten = [
          for (var i = 0; i < 3; i++)
            _verfolge(fake.call(HelperOp.write, _schreiben([i, i, i]))),
        ];
        async.flushMicrotasks();
        expect(antworten.map((a) => a.wert), everyElement(isEmpty));
        expect(ablauf, ['01 01', '01 01', '01 01']);
        async.elapse(const Duration(milliseconds: 2499));
        expect(ablauf, hasLength(3));
        async.elapse(const Duration(milliseconds: 1));
        expect(ablauf.last, '1a 0f 0c');
        expect(m110.pakete, [
          [0, 0, 0],
          [1, 1, 1],
          [2, 2, 2],
        ]);
        expect(m110.etiketten, 1);

        // Ein zweites connect meldet connected erneut.
        ablauf.clear();
        _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
        async.flushMicrotasks();
        expect(ablauf, ['connected']);
        expect(m110.verbindungen, 1);
        _stoppen(fake, async);
      });
    });

    test('ohne Abo von ff03 nimmt der M110 Pakete an, druckt aber nichts', () {
      fakeAsync((async) {
        final m110 = FakeM110();
        final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
        _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
        final ohneAbo = [
          for (var i = 0; i < 2; i++)
            _verfolge(fake.call(HelperOp.write, _schreiben([i]))),
        ];
        async.elapse(const Duration(seconds: 5));
        expect(ohneAbo.map((a) => a.wert), everyElement(isEmpty));
        expect(m110.pakete, hasLength(2));
        expect(m110.gedruckt, isFalse);
        expect(m110.meldungen, isEmpty);

        _verfolge(fake.call(HelperOp.subscribe, _merkmal('ff03')));
        _verfolge(fake.call(HelperOp.write, _schreiben([9])));
        async.elapse(const Duration(seconds: 3));
        expect(m110.gedruckt, isTrue);
        expect(m110.meldungen.map((m) => m.toList()), [
          [0x02, 0xb6, 0x00],
          [0x01, 0x01],
          [0x1a, 0x0f, 0x0c],
        ]);
        _stoppen(fake, async);
      });
    });

    test('Fehler wie das Hilfsprogramm: Länge, Schreibart, Merkmal, Gerät', () {
      fakeAsync((async) {
        final m110 = FakeM110();
        final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
        String? code(String op, Map<String, Object?> args) {
          final a = _verfolge(fake.call(op, args));
          async.flushMicrotasks();
          return a.code;
        }

        expect(code(HelperOp.write, _schreiben([1])), 'not_connected');
        expect(
          code(HelperOp.connect, {
            'device': '7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f',
          }),
          'unknown_device',
        );
        expect(code(HelperOp.connect, {'device': m110.id}), isNull);
        expect(
          code(
            HelperOp.write,
            _schreiben(List<int>.filled(21, 0), mitAntwort: false),
          ),
          'write_failed',
        );
        expect(
          code(HelperOp.write, _schreiben(List<int>.filled(513, 0))),
          'write_failed',
        );
        expect(
          code(
            HelperOp.write,
            _schreiben(List<int>.filled(20, 0), mitAntwort: false),
          ),
          isNull,
        );
        expect(
          code(HelperOp.write, _schreiben(List<int>.filled(512, 0))),
          isNull,
        );
        expect(m110.pakete.map((b) => b.length), [20, 512]);
        expect(
          code(HelperOp.subscribe, _merkmal('ff02')),
          'unsupported_operation',
        );
        expect(code(HelperOp.read, _merkmal('ff02')), 'unsupported_operation');
        expect(code(HelperOp.read, _merkmal('ff09')), 'unknown_characteristic');
        final lesen = _verfolge(fake.call(HelperOp.read, _merkmal('ff01')));
        async.flushMicrotasks();
        expect(lesen.wert, {'data': ''});
        expect(fake.befehle.map((b) => b.op), contains(HelperOp.read));
        _stoppen(fake, async);
      });
    });

    test('von anderem Gerät gehalten oder aus: connect wartet, bis er frei '
        'ist; aus trennt', () {
      fakeAsync((async) {
        final m110 = FakeM110()..vonAnderemGeraetGehalten = true;
        final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
        final ereignisse = <String>[];
        fake.events.listen((e) => ereignisse.add(e.event));
        final verbinden = _verfolge(
          fake.call(HelperOp.connect, {'device': m110.id}),
        );
        async.elapse(const Duration(seconds: 10));
        expect(verbinden.fertig, isFalse);
        m110.vonAnderemGeraetGehalten = false;
        async.flushMicrotasks();
        expect(verbinden.wert, isEmpty);
        expect(m110.verbunden, isTrue);

        m110.aus = true;
        async.flushMicrotasks();
        expect(ereignisse.last, 'disconnected');
        expect(m110.verbunden, isFalse);
        final nochmal = _verfolge(
          fake.call(HelperOp.connect, {'device': m110.id}),
        );
        async.elapse(const Duration(seconds: 5));
        expect(nochmal.fertig, isFalse);
        // disconnect bricht das wartende connect ab.
        final trennen = _verfolge(
          fake.call(HelperOp.disconnect, {'device': m110.id}),
        );
        async.flushMicrotasks();
        expect(nochmal.code, 'not_connected');
        expect(trennen.wert, isEmpty);

        // Wieder an: das nächste connect geht sofort.
        m110.aus = false;
        final zurueck = _verfolge(
          fake.call(HelperOp.connect, {'device': m110.id}),
        );
        async.flushMicrotasks();
        expect(zurueck.wert, isEmpty);
        expect(m110.verbindungen, 2);
        _stoppen(fake, async);
      });
    });

    test('Bluetooth aus trennt und lehnt ab, poweredOn geht wieder', () {
      fakeAsync((async) {
        final m110 = FakeM110();
        final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
        final ereignisse = <HelperEvent>[];
        fake.events.listen(ereignisse.add);
        _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
        async.flushMicrotasks();

        ereignisse.clear();
        fake.setzeZustand('poweredOff');
        async.flushMicrotasks();
        expect(fake.state, 'poweredOff');
        expect(ereignisse.map((e) => e.encode()), [
          '{"event":"state","state":"poweredOff"}',
          '{"event":"disconnected","device":"$fakeM110Id",'
              '"reason":"bluetooth poweredOff"}',
        ]);
        final aus = _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
        async.flushMicrotasks();
        expect(aus.code, 'bluetooth_off');

        fake.setzeZustand('poweredOn');
        final an = _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
        async.flushMicrotasks();
        expect(an.wert, isEmpty);
        expect(fake.state, 'poweredOn');
        _stoppen(fake, async);
      });
    });

    test(
      'Suche: Name mit dem zweiten Fund, verbundene Geräte werben nicht',
      () {
        fakeAsync((async) {
          final m110 = FakeM110(nameErstSpaeter: true);
          final zweiter = FakeM110(
            id: '7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f',
            name: 'Q199E00001',
          );
          final fake = FakeBluetoothHelper(log: log, geraete: [m110, zweiter]);
          final funde = <Map<String, Object?>>[];
          fake.events
              .where((e) => e.event == 'discovered')
              .listen((e) => funde.add(e.data));
          _verfolge(fake.call(HelperOp.connect, {'device': zweiter.id}));
          final suche = _verfolge(fake.call(HelperOp.scan, {'ms': 4000}));
          async.elapse(const Duration(milliseconds: 3999));
          expect(suche.fertig, isFalse);
          async.elapse(const Duration(milliseconds: 1));
          expect(suche.wert, isEmpty);
          expect(funde.map((f) => (f['device'], f['name'])), [
            (fakeM110Id, null),
            (fakeM110Id, 'Q199E00000'),
          ]);
          _stoppen(fake, async);
        });
      },
    );

    test(
      'trennt die leere Verbindung; Absturz verwirft den halben Auftrag',
      () {
        fakeAsync((async) {
          final m110 = FakeM110()
            ..trenntLeereVerbindungNach = const Duration(minutes: 1);
          final fake = FakeBluetoothHelper(log: log, geraete: [m110]);
          final ereignisse = <HelperEvent>[];
          fake.events.listen(ereignisse.add);
          _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
          async.elapse(const Duration(seconds: 59));
          expect(m110.verbunden, isTrue);
          async.elapse(const Duration(seconds: 1));
          expect(m110.verbunden, isFalse);
          expect(ereignisse.last.event, 'disconnected');

          m110.trenntLeereVerbindungNach = null;
          _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
          _verfolge(fake.call(HelperOp.subscribe, _merkmal('ff03')));
          _verfolge(fake.call(HelperOp.write, _schreiben([1])));
          async.flushMicrotasks();
          fake.abstuerzen();
          async.elapse(const Duration(seconds: 5));
          expect(m110.gedruckt, isFalse);
          expect(m110.verbunden, isFalse);

          // Nach dem Neustart ist auch das Abo weg; 02 b6 00 kommt erneut.
          _verfolge(fake.call(HelperOp.connect, {'device': m110.id}));
          async.flushMicrotasks();
          expect(m110.abonniert, isFalse);
          _verfolge(fake.call(HelperOp.subscribe, _merkmal('ff03')));
          async.flushMicrotasks();
          expect(_hex(ereignisse.last), '02 b6 00');
          _stoppen(fake, async);
        });
      },
    );
  });
}
