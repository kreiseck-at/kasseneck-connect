import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Schreibt mit, wann „belegt“ und „frei“ kamen.
class _Mitschrift implements BetriebsBeobachter {
  final List<String> ereignisse = <String>[];

  @override
  void belegt() => ereignisse.add('belegt');

  @override
  void frei() => ereignisse.add('frei');
}

void main() {
  group('LaufendeVorgaenge', () {
    test('ein Übergang je Belegung, gleich wie viele Vorgänge', () {
      final mitschrift = _Mitschrift();
      final v = LaufendeVorgaenge(beobachter: <BetriebsBeobachter>[mitschrift]);
      final a = v.beginne(VorgangsArt.druck);
      final b = v.beginne(VorgangsArt.terminal);
      expect(v.anzahl, 2);
      v
        ..beende(a)
        ..beende(a);
      expect(v.laufen, isTrue);
      v.beende(b);
      expect(v.laufen, isFalse);
      expect(mitschrift.ereignisse, <String>['belegt', 'frei']);
      v.stop();
    });

    test('ein nie beendeter Vorgang läuft nach sechs Minuten ab', () {
      fakeAsync((async) {
        final start = DateTime(2026, 11, 10, 9);
        final mitschrift = _Mitschrift();
        final v = LaufendeVorgaenge(
          clock: () => start.add(async.elapsed),
          beobachter: <BetriebsBeobachter>[mitschrift],
        );
        v.beginne(VorgangsArt.terminal);
        async.elapse(vorgangHoechstdauer - const Duration(seconds: 1));
        expect(v.laufen, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(mitschrift.ereignisse, <String>['belegt', 'frei']);
        expect(v.laufen, isFalse);
      });
    });

    test('leer() wartet auf den letzten Vorgang oder bis zur Frist', () async {
      final v = LaufendeVorgaenge();
      expect(await v.leer(hoechstens: Duration.zero), isTrue);
      final a = v.beginne(VorgangsArt.druck);
      final warten = v.leer(hoechstens: const Duration(seconds: 5));
      Timer(const Duration(milliseconds: 20), () => v.beende(a));
      expect(await warten, isTrue);
      final b = v.beginne(VorgangsArt.druck);
      expect(
        await v.leer(hoechstens: const Duration(milliseconds: 30)),
        isFalse,
      );
      v
        ..beende(b)
        ..stop();
    });
  });

  group('betrieb.lock', () {
    late Directory temp;
    late ConfigStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('connect-betrieb-');
      store = ConfigStore.forDirectory(temp);
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('steht, solange ein Vorgang läuft; ein schnelles „belegt, frei“ '
        'lässt keine Datei liegen', () async {
      final lock = BetriebsLock(store: store);
      final v = LaufendeVorgaenge(beobachter: <BetriebsBeobachter>[lock]);
      final a = v.beginne(VorgangsArt.terminal);
      await lock.erledigt;
      final inhalt =
          jsonDecode(lock.datei.readAsStringSync()) as Map<String, Object?>;
      expect(inhalt['pid'], pid);
      v.beende(a);
      await lock.erledigt;
      expect(lock.datei.existsSync(), isFalse);

      for (var i = 0; i < 20; i++) {
        v.beende(v.beginne(VorgangsArt.druck));
      }
      await lock.erledigt;
      expect(lock.datei.existsSync(), isFalse);
      v.stop();
    });

    test('busy_lock aus: keine Datei', () async {
      await store.mutate(
        (c) => c.copyWith(disabledFeatures: <String>['busy_lock']),
      );
      final lock = BetriebsLock(store: store)..belegt();
      await lock.erledigt;
      expect(lock.datei.existsSync(), isFalse);
    });

    test(
      'frisch heißt jünger als sechs Minuten; aus der Zukunft zählt nicht',
      () {
        final jetzt = DateTime(2026, 11, 10, 9);
        expect(betriebLockIstFrisch(jetzt, jetzt), isTrue);
        expect(
          betriebLockIstFrisch(
            jetzt.subtract(betriebLockFrisch - const Duration(seconds: 1)),
            jetzt,
          ),
          isTrue,
        );
        expect(
          betriebLockIstFrisch(jetzt.subtract(betriebLockFrisch), jetzt),
          isFalse,
        );
        expect(
          betriebLockIstFrisch(jetzt.add(const Duration(minutes: 1)), jetzt),
          isFalse,
        );
      },
    );

    test('das Warten des Installers: frei sofort, frisch bis zur Frist, '
        'gelöscht sofort weiter', () async {
      final datei = betriebLockDatei(temp);
      expect(
        await warteAufFreienBetrieb(datei),
        lessThan(const Duration(milliseconds: 100)),
      );

      datei.writeAsStringSync('{}');
      var uhr = DateTime.now();
      final schlaefe = <Duration>[];
      final gewartet = await warteAufFreienBetrieb(
        datei,
        hoechstens: const Duration(seconds: 10),
        clock: () => uhr,
        schlafe: (d) async {
          schlaefe.add(d);
          uhr = uhr.add(d);
        },
      );
      expect(gewartet, const Duration(seconds: 10));
      expect(schlaefe, hasLength(5));

      final echt = warteAufFreienBetrieb(
        datei,
        takt: const Duration(milliseconds: 10),
      );
      Timer(const Duration(milliseconds: 50), datei.deleteSync);
      expect(
        await echt.timeout(const Duration(seconds: 5)),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test(
      'Prozess stirbt mitten im Vorgang: nach Ablauf wieder frei',
      () async {
        final worker = p.join('test', 'support', 'betrieb_worker.dart');
        final prozess = await Process.start(
          Platform.resolvedExecutable,
          <String>['run', worker, temp.path],
        );
        final bereit = Completer<void>();
        final abo = prozess.stdout.transform(utf8.decoder).listen((t) {
          if (t.contains('bereit') && !bereit.isCompleted) bereit.complete();
        });
        prozess.stderr.drain<void>().ignore();
        await bereit.future.timeout(const Duration(seconds: 60));
        expect(prozess.kill(ProcessSignal.sigkill), isTrue);
        await prozess.exitCode;
        await abo.cancel();

        final datei = betriebLockDatei(temp);
        expect(
          datei.existsSync(),
          isTrue,
          reason: 'der Absturz räumt nicht auf',
        );
        final geaendert = datei.lastModifiedSync();
        // Gleich nach dem Absturz wartet der Installer noch …
        expect(betriebLockIstFrisch(geaendert, DateTime.now()), isTrue);
        // … nach sechs Minuten nicht mehr.
        final spaeter = geaendert.add(betriebLockFrisch);
        expect(
          await warteAufFreienBetrieb(datei, clock: () => spaeter),
          Duration.zero,
        );
        // Und der nächste Start räumt die Datei weg.
        final agent = Agent(
          store: store,
          log: AgentLog(Directory(p.join(temp.path, 'logs'))),
          preferredPort: 0,
          openBrowser: false,
          environment: const <String, String>{},
          betriebssystem: 'linux',
        );
        await agent.start();
        await agent.stop();
        expect(datei.existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('Schlafsperre', () {
    late Directory temp;
    late ConfigStore store;
    late FakeProcessRunner prozesse;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('connect-schlaf-');
      store = ConfigStore.forDirectory(temp);
      // caffeinate läuft, bis es beendet wird.
      prozesse = FakeProcessRunner()
        ..antwort = (programm, _) => programm == 'caffeinate'
            ? Completer<ProcessResult>().future
            : Future<ProcessResult?>.value();
    });

    tearDown(() => temp.deleteSync(recursive: true));

    Schlafsperre sperre(String os, {LeerlaufZuruecksetzen? windows}) =>
        Schlafsperre(
          store: store,
          betriebssystem: os,
          start: prozesse.starter,
          eigenePid: 4711,
          windows: windows,
          auffrischen: const Duration(milliseconds: 20),
          hoechstdauer: const Duration(milliseconds: 200),
        );

    test(
      'macOS: ein caffeinate für alle Vorgänge, beendet nach dem letzten',
      () async {
        final s = sperre('macos');
        final v = LaufendeVorgaenge(beobachter: <BetriebsBeobachter>[s]);
        final a = v.beginne(VorgangsArt.druck);
        final b = v.beginne(VorgangsArt.terminal);
        await s.erledigt;
        expect(prozesse.calls, hasLength(1));
        expect(
          prozesse.sawCall('caffeinate', <String>[
            '-i',
            '-w',
            '4711',
            '-t',
            '0',
          ]),
          isTrue,
          reason: '${prozesse.lines}',
        );
        expect(s.aktiv, isTrue);
        v.beende(a);
        await s.erledigt;
        expect(prozesse.killed, isEmpty);
        v.beende(b);
        await s.erledigt;
        expect(prozesse.killed, hasLength(1));
        expect(s.aktiv, isFalse);
        v.stop();
      },
    );

    test('macOS mit echter Frist: -t 360', () async {
      final s = Schlafsperre(
        store: store,
        betriebssystem: 'macos',
        start: prozesse.starter,
        eigenePid: 4711,
      )..belegt();
      await s.erledigt;
      expect(
        prozesse.sawCall('caffeinate', <String>[
          '-i',
          '-w',
          '4711',
          '-t',
          '360',
        ]),
        isTrue,
      );
      s.frei();
      await s.erledigt;
    });

    test(
      'sleep_lock aus, Linux oder fehlendes caffeinate: keine Sperre',
      () async {
        await store.mutate(
          (c) => c.copyWith(disabledFeatures: <String>['sleep_lock']),
        );
        final aus = sperre('macos')..belegt();
        await aus.erledigt;
        expect(aus.aktiv, isFalse);
        await store.mutate((c) => c.copyWith(disabledFeatures: <String>[]));
        final linux = sperre('linux')..belegt();
        await linux.erledigt;
        expect(linux.aktiv, isFalse);
        expect(prozesse.calls, isEmpty);
        prozesse.missing.add('caffeinate');
        final ohne = sperre('macos')..belegt();
        await ohne.erledigt;
        expect(ohne.aktiv, isFalse);
      },
    );

    test('Windows: Leerlauf zurücksetzen sofort und im Takt, endet mit dem '
        'Vorgang oder nach der Höchstdauer', () async {
      var aufrufe = 0;
      final s = sperre('windows', windows: () => aufrufe++)..belegt();
      await s.erledigt;
      expect(aufrufe, 1);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(aufrufe, greaterThanOrEqualTo(2));
      s.frei();
      await s.erledigt;
      final nachFrei = aufrufe;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(aufrufe, nachFrei);

      s.belegt();
      await s.erledigt;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(s.aktiv, isFalse, reason: 'Höchstdauer');
    });
  });
}
