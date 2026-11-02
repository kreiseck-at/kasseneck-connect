import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Ob der Prozess [pid] noch lebt: ein harmloses SIGCONT kommt nur bei einem
/// lebenden Prozess an (ohne `kill`-Programm, das schlanke Linux-Abbilder
/// nicht haben).
bool _lebt(int pid) => Process.killPid(pid, ProcessSignal.sigcont);

void main() {
  group('runWithTimeout', () {
    test('liefert Exitcode und Ausgaben wie Process.run', () async {
      final ergebnis = await runWithTimeout(Process.start, '/bin/sh', <String>[
        '-c',
        'echo hallo; echo fehler >&2; exit 3',
      ], const Duration(seconds: 10));

      expect(ergebnis, isNotNull);
      expect(ergebnis!.exitCode, 3);
      expect(ergebnis.stdout, 'hallo\n');
      expect(ergebnis.stderr, 'fehler\n');
    }, testOn: '!windows');

    test('beendet ein Programm, das die Zeitgrenze überschreitet', () async {
      Process? gestartet;
      Future<Process> merken(String programm, List<String> argumente) async =>
          gestartet = await Process.start(programm, argumente);

      final uhr = Stopwatch()..start();
      final ergebnis = await runWithTimeout(merken, '/bin/sleep', <String>[
        '30',
      ], const Duration(milliseconds: 200));

      expect(ergebnis, isNull);
      // Nicht nur aufgegeben: der Prozess ist tot, und das ohne die 30 s.
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await gestartet!.exitCode, isNot(0));
      expect(_lebt(gestartet!.pid), isFalse);
    }, testOn: '!windows');

    test('überhört es SIGTERM, kommt SIGKILL', () async {
      Process? gestartet;
      Future<Process> merken(String programm, List<String> argumente) async =>
          gestartet = await Process.start(programm, argumente);

      // `exec` behält das ignorierte SIGTERM: der schlafende Prozess selbst
      // überhört es.
      final ergebnis = await runWithTimeout(
        merken,
        '/bin/sh',
        <String>['-c', 'trap "" TERM; exec /bin/sleep 30'],
        const Duration(milliseconds: 200),
        killGrace: const Duration(milliseconds: 200),
      );

      expect(ergebnis, isNull);
      await gestartet!.exitCode.timeout(const Duration(seconds: 5));
      expect(_lebt(gestartet!.pid), isFalse);
    }, testOn: '!windows');

    test('fehlendes Programm: null statt Ausnahme', () async {
      expect(
        await runWithTimeout(
          Process.start,
          '/gibt/es/nicht',
          const <String>[],
          const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('Attrappe: hängende Antwort wird beendet und gezählt', () async {
      final fake = FakeProcessRunner()
        ..antwort = (_, _) => Completer<ProcessResult>().future;

      expect(
        await runWithTimeout(fake.starter, '/usr/bin/security', <String>[
          'verify-cert',
        ], const Duration(milliseconds: 50)),
        isNull,
      );
      expect(fake.killed.single.arguments, <String>['verify-cert']);
    });
  });

  group('processStarterFrom', () {
    test('reicht Ergebnis und fehlende Programme des Runners durch', () async {
      final fake = FakeProcessRunner()
        ..exitCodes['verify-cert'] = 1
        ..stdoutOf['verify-cert'] = 'nicht vertraut';
      final start = processStarterFrom(fake.runner);

      final ergebnis = await runWithTimeout(
        start,
        '/usr/bin/security',
        <String>['verify-cert'],
        const Duration(seconds: 1),
      );
      expect(ergebnis!.exitCode, 1);
      expect(ergebnis.stdout, 'nicht vertraut');
      expect(fake.calls.single.arguments, <String>['verify-cert']);

      fake.missing.add('/usr/bin/security');
      expect(
        await runWithTimeout(start, '/usr/bin/security', <String>[
          'verify-cert',
        ], const Duration(seconds: 1)),
        isNull,
      );
    });
  });
}
