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
    // Die Diagnose fragt am Mac den Schlüsselbund — im Test nie echt.
    runProcess: FakeProcessRunner().runner,
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

    test('Bluetooth-Hilfsprogramm: vorhanden neben der Binary, sonst '
        'fehlt', () async {
      final programm = Directory(p.join(temp.path, 'paket'))..createSync();
      final binary = p.join(programm.path, 'kasseneck-connect');

      Future<DoctorReport> bericht(String os) => collectDoctorReport(
        paths: paths,
        probe: noAgent,
        printerStates: noPrinters,
        autostart: FakeAutostart(),
        operatingSystem: os,
        executable: binary,
        environment: const <String, String>{},
      );

      final ohne = await bericht('macos');
      expect(ohne.bluetoothHelper, isNull);
      expect(
        formatDoctorReport(ohne),
        contains('Bluetooth-Hilfsprogramm: fehlt'),
      );

      final helfer = File(p.join(programm.path, bluetoothHelperName))
        ..writeAsStringSync('');
      final mit = await bericht('macos');
      expect(mit.bluetoothHelper, helfer.path);
      expect(
        formatDoctorReport(mit),
        contains('Bluetooth-Hilfsprogramm: vorhanden (${helfer.path})'),
      );

      // Außerhalb von macOS gibt es keines – das Hilfsprogramm daneben zählt
      // dort nicht.
      final windows = await bericht('windows');
      expect(windows.bluetoothHelper, isNull);
      expect(
        formatDoctorReport(windows),
        contains(
          'Bluetooth-Hilfsprogramm: fehlt (Bluetooth gibt es bisher '
          'nur am Mac)',
        ),
      );
    });

    test('nennt, ob der laufende Agent Bluetooth anbietet', () async {
      StatusProbe mitFeatures(List<String> features) =>
          (int port) async => port == 27182
          ? <String, Object?>{
              'ok': true,
              'version': agentVersion,
              'port': port,
              'paired': true,
              'uptimeSeconds': 5,
              'features': features,
            }
          : null;

      Future<String> text(List<String> features) async => formatDoctorReport(
        await collectDoctorReport(
          paths: paths,
          probe: mitFeatures(features),
          printerStates: noPrinters,
          autostart: FakeAutostart(),
        ),
      );

      expect(
        await text(<String>['bluetooth']),
        contains('Agent: mit Bluetooth'),
      );
      expect(await text(<String>[]), contains('Agent: ohne Bluetooth'));
      // Ohne laufenden Agenten steht dazu nichts.
      final ohneAgent = formatDoctorReport(
        await collectDoctorReport(
          paths: paths,
          probe: noAgent,
          printerStates: noPrinters,
          autostart: FakeAutostart(),
        ),
      );
      expect(ohneAgent, isNot(contains('Agent: mit')));
      expect(ohneAgent, isNot(contains('Agent: ohne')));
    });

    test('doctor berührt Bluetooth nicht', () async {
      // Stolperdraht: ein Hilfsprogramm, das beim Start eine Marke
      // hinterlegt. Die Diagnose darf es finden, aber nie starten – sonst
      // fragte macOS im Namen des Terminals nach Bluetooth.
      final marke = File(p.join(temp.path, 'gestartet'));
      final helfer = File(p.join(temp.path, bluetoothHelperName))
        ..writeAsStringSync('#!/bin/sh\necho gestartet > "${marke.path}"\n');
      final chmod = await Process.run('chmod', <String>['755', helfer.path]);
      expect(chmod.exitCode, 0);

      final report = await collectDoctorReport(
        paths: paths,
        probe: noAgent,
        printerStates: noPrinters,
        autostart: FakeAutostart(),
        operatingSystem: 'macos',
        environment: <String, String>{bluetoothHelperEnvVar: helfer.path},
      );
      final text = formatDoctorReport(report);
      expect(text, contains('Bluetooth-Hilfsprogramm: vorhanden'));

      // Ein Start liefe im Hintergrund: kurz warten, ob die Marke kommt.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(marke.existsSync(), isFalse);
      expect(readRecentErrors(paths.logDirectory), isEmpty);
    }, testOn: '!windows');
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
  group('HTTPS', () {
    late FakeProcessRunner runner;

    setUp(() => runner = FakeProcessRunner()..exitCodes['verify-cert'] = 1);

    /// Zertifikate im Datenordner; `openssl x509` (Attrappe) meldet den Ablauf.
    void zertifikate() {
      final tls = Directory(p.join(temp.path, 'tls'))..createSync();
      File(p.join(tls.path, 'ca-cert.pem')).writeAsStringSync('stelle');
      File(p.join(tls.path, 'server-cert.pem')).writeAsStringSync('server');
      runner.stdoutOf['x509'] =
          'notAfter=Nov 30 12:00:00 2027 GMT\n'
          '-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n';
    }

    StatusProbe agentMitHttps(int? httpsPort) =>
        (int port) async => port == 27182
        ? <String, Object?>{
            'ok': true,
            'version': agentVersion,
            'port': port,
            'httpsPort': httpsPort,
            'paired': true,
            'uptimeSeconds': 5,
            'features': <String>[if (httpsPort != null) 'https'],
          }
        : null;

    Future<String> bericht({String os = 'macos', StatusProbe? probe}) async =>
        formatDoctorReport(
          await collectDoctorReport(
            paths: paths,
            probe: probe ?? agentMitHttps(27190),
            printerStates: noPrinters,
            autostart: FakeAutostart(),
            operatingSystem: os,
            environment: const <String, String>{},
            runProcess: runner.runner,
          ),
        );

    test('Zeile mit Port, Ablauf und Vertrauen', () async {
      zertifikate();
      runner.exitCodes['verify-cert'] = 0;

      final text = await bericht();

      expect(
        text,
        contains(
          'HTTPS: Port 27190, Zertifikat gültig bis 2027-11-30, vertraut ja',
        ),
      );
      expect(text, isNot(contains('zertifikat-vertrauen')));
      // Die Diagnose liest nur: Ablauf über openssl, Vertrauen über
      // `security verify-cert` — nie eintragen, nie neu anlegen.
      expect(
        runner.calls.map((c) => c.arguments.first),
        unorderedEquals(<String>['x509', 'verify-cert']),
      );
    });

    test('nicht vertraut: „vertraut nein“ und der Weg dahin', () async {
      zertifikate();

      final text = await bericht();

      expect(
        text,
        contains(
          'HTTPS: Port 27190, Zertifikat gültig bis 2027-11-30, vertraut nein',
        ),
      );
      expect(text, contains('kasseneck-connect zertifikat-vertrauen'));
    });

    test('Agent ohne HTTPS-Zugang: aus', () async {
      zertifikate();
      runner.exitCodes['verify-cert'] = 0;

      expect(
        await bericht(probe: agentMitHttps(null)),
        contains('HTTPS: aus, Zertifikat gültig bis 2027-11-30, vertraut ja'),
      );
    });

    test('ohne Zertifikat: nichts wird aufgerufen oder angelegt', () async {
      final text = await bericht();

      expect(
        text,
        contains('HTTPS: Port 27190, kein Zertifikat, vertraut nein'),
      );
      expect(runner.calls, isEmpty);
      expect(Directory(p.join(temp.path, 'tls')).existsSync(), isFalse);
    });

    test('unlesbares Zertifikat wird so genannt', () async {
      zertifikate();
      runner.exitCodes['x509'] = 1;

      expect(await bericht(), contains('Zertifikat unlesbar'));
    });

    test('außerhalb von macOS: Hinweis, kein Programmaufruf', () async {
      zertifikate();

      final text = await bericht(os: 'windows');

      expect(text, contains('HTTPS: gibt es bisher nur am Mac'));
      expect(runner.calls, isEmpty);
    });

    test('DoctorPort liest httpsPort aus der Kurzform', () async {
      final report = await collectDoctorReport(
        paths: paths,
        probe: agentMitHttps(27191),
        printerStates: noPrinters,
        autostart: FakeAutostart(),
        operatingSystem: 'macos',
        runProcess: runner.runner,
      );
      expect(report.runningOn?.httpsPort, 27191);
    });
  });
}
