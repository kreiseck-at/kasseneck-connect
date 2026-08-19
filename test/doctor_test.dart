import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Autostart-Doppelgänger: meldet einen Zustand, ohne das System anzufassen.
class FakeAutostart implements Autostart {
  FakeAutostart({this.installed = false, this.result});

  bool installed;
  AutostartResult? result;
  int installCalls = 0;
  int uninstallCalls = 0;

  @override
  String get target => '/pfad/zum/eintrag';

  @override
  Future<bool> isInstalled() async => installed;

  @override
  Future<AutostartResult> install() async {
    installCalls++;
    installed = true;
    return result ?? const AutostartResult.success('Autostart eingerichtet.');
  }

  @override
  Future<AutostartResult> uninstall() async {
    uninstallCalls++;
    installed = false;
    return result ?? const AutostartResult.success('Autostart entfernt.');
  }
}

void main() {
  late Directory temp;
  late ConfigPaths paths;
  late ConfigStore store;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-doctor-');
    paths = ConfigPaths(temp);
    store = ConfigStore(paths);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// Kein Port antwortet.
  Future<Map<String, Object?>?> noAgent(int port) async => null;

  /// Nur [port] antwortet.
  StatusProbe agentOn(int port, {bool paired = true}) =>
      (int candidate) async => candidate == port
      ? <String, Object?>{
          'ok': true,
          'version': agentVersion,
          'os': 'macos',
          'port': port,
          'paired': paired,
          'uptimeSeconds': 3600,
        }
      : null;

  Future<List<Map<String, Object?>>> noPrinters() async =>
      <Map<String, Object?>>[];

  Future<int> runDoctor({
    StatusProbe? probe,
    PrinterStates? printers,
    Autostart? autostart,
  }) => runCli(
    <String>['doctor'],
    out: out,
    err: err,
    paths: paths,
    statusProbe: probe ?? noAgent,
    printerStates: printers ?? noPrinters,
    autostart: autostart ?? FakeAutostart(),
  );

  group('Bericht sammeln', () {
    test('probiert die ganze Portreihe 27182–27189 durch', () async {
      final probed = <int>[];
      await collectDoctorReport(
        paths: paths,
        probe: (int port) async {
          probed.add(port);
          return null;
        },
        printerStates: noPrinters,
        autostart: FakeAutostart(),
      );

      expect(probed, <int>[
        27182,
        27183,
        27184,
        27185,
        27186,
        27187,
        27188,
        27189,
      ]);
    });

    test('findet den Agenten auf einem Ausweichport', () async {
      final report = await collectDoctorReport(
        paths: paths,
        probe: agentOn(27184),
        printerStates: noPrinters,
        autostart: FakeAutostart(),
      );

      expect(report.runningOn?.port, 27184);
      expect(report.runningOn?.version, agentVersion);
      expect(report.runningOn?.uptimeSeconds, 3600);
    });

    test('zählt die gekoppelten Kassen aus der Konfiguration', () async {
      await store.mutate(
        (c) => c.copyWith(tokenHashes: <String>['aaa', 'bbb']),
      );

      final report = await collectDoctorReport(
        paths: paths,
        probe: noAgent,
        printerStates: noPrinters,
        autostart: FakeAutostart(),
      );

      expect(report.tokenCount, 2);
      expect(report.paired, isTrue);
    });

    test('nennt Konfigurations- und Logpfad', () async {
      final report = await collectDoctorReport(
        paths: paths,
        probe: noAgent,
        printerStates: noPrinters,
        autostart: FakeAutostart(),
      );

      expect(report.configFile, p.join(temp.path, 'config.json'));
      expect(report.logFile, p.join(temp.path, 'logs', 'connect.log'));
    });

    test('übernimmt den Autostart-Zustand', () async {
      final report = await collectDoctorReport(
        paths: paths,
        probe: noAgent,
        printerStates: noPrinters,
        autostart: FakeAutostart(installed: true),
      );

      expect(report.autostartInstalled, isTrue);
      expect(report.autostartTarget, '/pfad/zum/eintrag');
    });

    test('liest die letzten Fehler aus dem Log', () async {
      final log = AgentLog(paths.logDirectory)
        ..info('alles gut')
        ..error('Drucker weg', 'SocketException')
        ..warn('nur eine Warnung')
        ..error('zweiter Fehler');
      expect(log.file.existsSync(), isTrue);

      final report = await collectDoctorReport(
        paths: paths,
        probe: noAgent,
        printerStates: noPrinters,
        autostart: FakeAutostart(),
      );

      expect(report.lastErrors, hasLength(2));
      expect(report.lastErrors.first, contains('Drucker weg'));
      expect(report.lastErrors.last, contains('zweiter Fehler'));
      expect(report.lastErrors.join(), isNot(contains('nur eine Warnung')));
    });

    test('zeigt höchstens zehn Fehler, die jüngsten zuletzt', () async {
      final log = AgentLog(paths.logDirectory);
      for (var i = 0; i < 15; i++) {
        log.error('Fehler $i');
      }

      final errors = readRecentErrors(paths.logDirectory);
      expect(errors, hasLength(10));
      expect(errors.first, contains('Fehler 5'));
      expect(errors.last, contains('Fehler 14'));
    });

    test('ohne Log gibt es keine Fehler', () {
      expect(
        readRecentErrors(Directory(p.join(temp.path, 'gibtsnicht'))),
        isEmpty,
      );
    });
  });

  group('Ausgabe', () {
    test('nennt Version, Pfade und Kopplung', () async {
      await store.mutate((c) => c.copyWith(tokenHashes: <String>['aaa']));
      expect(await runDoctor(), 0);

      final text = out.toString();
      expect(text, contains('$agentName $agentVersion'));
      expect(text, contains(p.join(temp.path, 'config.json')));
      expect(text, contains(p.join(temp.path, 'logs', 'connect.log')));
      expect(text, contains('Kopplung'));
      expect(text, contains('ja (1 Kasse)'));
    });

    test('sagt deutlich, wenn kein Agent läuft', () async {
      expect(await runDoctor(), 0);
      expect(out.toString(), contains('Kein Agent erreichbar auf 27182–27189'));
    });

    test('nennt den Port, an dem der Agent antwortet', () async {
      expect(await runDoctor(probe: agentOn(27183)), 0);
      final text = out.toString();
      expect(text, contains('Port 27183'));
      expect(text, contains('antwortet'));
      expect(text, contains('gekoppelt'));
    });

    test('führt die Drucker mit ihrem Zustand auf', () async {
      expect(
        await runDoctor(
          printers: () async => <Map<String, Object?>>[
            <String, Object?>{
              'id': 'p_abc',
              'name': 'Kasse',
              'kind': 'tcp9100',
              'host': '192.168.1.50',
              'port': 9100,
              'state': 'online',
            },
          ],
        ),
        0,
      );

      final text = out.toString();
      expect(text, contains('Kasse'));
      expect(text, contains('192.168.1.50:9100'));
      expect(text, contains('online'));
    });

    test('ohne Drucker steht das auch da', () async {
      expect(await runDoctor(), 0);
      expect(out.toString(), contains('keine eingetragen'));
    });

    test('zeigt den Autostart-Zustand mit Pfad', () async {
      expect(await runDoctor(autostart: FakeAutostart(installed: true)), 0);
      expect(out.toString(), contains('eingerichtet: /pfad/zum/eintrag'));

      out.clear();
      expect(await runDoctor(autostart: FakeAutostart()), 0);
      expect(out.toString(), contains('nicht eingerichtet'));
      expect(out.toString(), contains('install-autostart'));
    });

    test('führt die letzten Fehler auf', () async {
      AgentLog(paths.logDirectory).error('Drucker antwortet nicht');
      expect(await runDoctor(), 0);
      expect(out.toString(), contains('Drucker antwortet nicht'));
    });

    test('ohne Fehler steht „keine"', () async {
      expect(await runDoctor(), 0);
      expect(out.toString(), contains('Letzte Fehler'));
      expect(out.toString(), contains('keine'));
    });
  });

  group('Autostart über die Kommandozeile', () {
    test('install-autostart richtet ein und meldet Erfolg', () async {
      final autostart = FakeAutostart();
      final code = await runCli(
        <String>['install-autostart'],
        out: out,
        err: err,
        paths: paths,
        autostart: autostart,
      );

      expect(code, 0);
      expect(autostart.installCalls, 1);
      expect(out.toString(), contains('Autostart eingerichtet'));
      expect(err.toString(), isEmpty);
    });

    test('uninstall-autostart entfernt und meldet Erfolg', () async {
      final autostart = FakeAutostart(installed: true);
      final code = await runCli(
        <String>['uninstall-autostart'],
        out: out,
        err: err,
        paths: paths,
        autostart: autostart,
      );

      expect(code, 0);
      expect(autostart.uninstallCalls, 1);
      expect(out.toString(), contains('Autostart entfernt'));
    });

    test('ein Fehler endet mit Exit-Code 70 auf stderr', () async {
      final autostart = FakeAutostart(
        result: const AutostartResult.failure(
          'launchctl konnte den Autostart nicht laden.',
          detail: 'Input/output error',
        ),
      );
      final code = await runCli(
        <String>['install-autostart'],
        out: out,
        err: err,
        paths: paths,
        autostart: autostart,
      );

      expect(code, exitCodeFailed);
      expect(err.toString(), contains('launchctl'));
      expect(err.toString(), contains('Input/output error'));
      expect(out.toString(), isEmpty);
    });

    test('kein Befehl startet ein echtes Programm', () async {
      final runner = FakeProcessRunner();
      await runCli(
        <String>['doctor'],
        out: out,
        err: err,
        paths: paths,
        statusProbe: noAgent,
        printerStates: noPrinters,
        autostart: autostartForPlatform(
          operatingSystem: 'linux',
          environment: <String, String>{'HOME': temp.path},
          paths: paths,
          runProcess: runner.runner,
          executable: '/bin/connect',
        ),
      );

      expect(runner.calls, isEmpty);
    });
  });
}
