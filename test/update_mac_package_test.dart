import 'dart:io';

import 'package:kasseneck_connect/src/update/mac_package.dart';
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

String _fixture(String name) =>
    File('test/fixtures/update/$name').readAsStringSync();

void main() {
  final pkg = File('/tmp/KasseneckConnect-1.4.1-macos-arm64.pkg');
  final pkgutilEcht = _fixture('pkgutil-check-signature-1.3.0.txt');
  final spctlEcht = _fixture('spctl-install-1.3.0.txt');

  FakeProcessRunner runner({
    String pkgutil = '',
    String spctl = '',
    int pkgutilExit = 0,
    int spctlExit = 0,
  }) =>
      FakeProcessRunner()
        ..antwort = (executable, arguments) async => switch (executable) {
          // spctl schreibt sein Urteil auf stderr, pkgutil auf stdout.
          'pkgutil' => ProcessResult(1, pkgutilExit, pkgutil, ''),
          'spctl' => ProcessResult(2, spctlExit, '', spctl),
          _ => null,
        };

  test(
    'unser notarisiertes Paket (echte Ausgaben von 1.3.0) besteht',
    () async {
      final run = runner(pkgutil: pkgutilEcht, spctl: spctlEcht);
      expect(await verifyMacPackage(pkg, run: run.runner), isTrue);
      expect(
        run.sawCall('pkgutil', <String>['--check-signature', pkg.path]),
        isTrue,
      );
      expect(
        run.sawCall('spctl', <String>['-a', '-t', 'install', '-vv', pkg.path]),
        isTrue,
      );
    },
  );

  test('andere Team-ID fällt durch', () async {
    final fremd = pkgutilEcht.replaceAll(
      'POST NOW e.U. (6KMT4H4CNE)',
      'Jemand (ABCDEFGHIJ)',
    );
    final run = runner(
      pkgutil: fremd,
      spctl: spctlEcht.replaceAll('(6KMT4H4CNE)', '(ABCDEFGHIJ)'),
    );
    expect(await verifyMacPackage(pkg, run: run.runner), isFalse);
  });

  test('Team-ID nur in einer späteren Kettenzeile reicht nicht', () async {
    final verschoben = pkgutilEcht.replaceFirst(
      '1. Developer ID Installer: POST NOW e.U. (6KMT4H4CNE)',
      '1. Developer ID Installer: Jemand (ABCDEFGHIJ)\n    0. Developer ID Installer: POST NOW e.U. (6KMT4H4CNE)',
    );
    final run = runner(pkgutil: verschoben, spctl: spctlEcht);
    expect(await verifyMacPackage(pkg, run: run.runner), isFalse);
  });

  test('ohne Notarisierung fällt es durch', () async {
    final run = runner(
      pkgutil: pkgutilEcht,
      spctl: spctlEcht.replaceAll('Notarized Developer ID', 'Developer ID'),
    );
    expect(await verifyMacPackage(pkg, run: run.runner), isFalse);
  });

  test('ohne Apple-Wurzel fällt es durch', () async {
    final run = runner(
      pkgutil: pkgutilEcht.replaceAll('Apple Root CA', 'Eigene Wurzel'),
      spctl: spctlEcht,
    );
    expect(await verifyMacPackage(pkg, run: run.runner), isFalse);
  });

  test('Exit-Code ungleich 0 fällt durch', () async {
    expect(
      await verifyMacPackage(
        pkg,
        run: runner(
          pkgutil: pkgutilEcht,
          spctl: spctlEcht,
          pkgutilExit: 1,
        ).runner,
      ),
      isFalse,
    );
    expect(
      await verifyMacPackage(
        pkg,
        run: runner(
          pkgutil: pkgutilEcht,
          spctl: spctlEcht,
          spctlExit: 3,
        ).runner,
      ),
      isFalse,
    );
  });

  test('fehlendes Programm fällt durch, ohne zu werfen', () async {
    final run = FakeProcessRunner()
      ..missing.addAll(<String>['pkgutil', 'spctl']);
    expect(await verifyMacPackage(pkg, run: run.runner), isFalse);
  });
}
