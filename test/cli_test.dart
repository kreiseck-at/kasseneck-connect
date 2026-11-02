import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

const String _openssl = '/usr/bin/openssl';
const String _security = '/usr/bin/security';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late Directory temp;
  late ConfigPaths paths;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    temp = Directory.systemTemp.createTempSync('connect-cli-');
    paths = ConfigPaths(temp);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<int> run(
    List<String> args, {
    Future<void> Function()? shutdown,
    int? preferredPort,
  }) => runCli(
    args,
    out: out,
    err: err,
    paths: paths,
    awaitShutdown: shutdown,
    preferredPort: preferredPort,
    // Der Testlauf darf keinen echten Browser aufmachen.
    openBrowser: false,
    // HTTPS gibt es nur am Mac; hier bleibt `run` beim HTTP-Zugang und fasst
    // weder 27190 noch den Schlüsselbund an. Den HTTPS-Zugang prüfen
    // agent_test und die Tests von `zertifikat-vertrauen` unten.
    operatingSystem: 'linux',
    runProcess: FakeProcessRunner().runner,
  );

  test('version gibt Name und Version aus', () async {
    expect(await run(<String>['version']), 0);
    expect(out.toString().trim(), '$agentName $agentVersion');
    expect(err.toString(), isEmpty);
  });

  test('--version verhält sich gleich', () async {
    expect(await run(<String>['--version']), 0);
    expect(out.toString().trim(), '$agentName $agentVersion');
  });

  test('alle Befehle der Hilfe sind gebaut', () async {
    // Kein Befehl darf mehr „noch nicht verfügbar" melden. `run` klemmt bis
    // zum Abschaltsignal und `install-autostart` würde am echten System
    // schrauben — beide sind hier bewusst außen vor und in eigenen Tests
    // abgedeckt (cli_test „run …", doctor_test „Autostart über die
    // Kommandozeile").
    for (final command in <String>['pair', 'doctor', 'version']) {
      final buffer = StringBuffer();
      final code = await runCli(
        <String>[command],
        out: StringBuffer(),
        err: buffer,
        paths: paths,
        // Die Diagnose darf im Test weder Ports abklopfen noch Drucker
        // anfassen noch nach einem echten Autostart sehen.
        statusProbe: (int _) async => null,
        printerStates: () async => <Map<String, Object?>>[],
        runProcess: FakeProcessRunner().runner,
        autostart: autostartForPlatform(
          operatingSystem: 'linux',
          environment: <String, String>{'HOME': temp.path},
          paths: paths,
          runProcess: (String _, List<String> _) async =>
              ProcessResult(0, 0, '', ''),
          executable: '/bin/connect',
        ),
      );
      expect(code, 0, reason: command);
      expect(
        buffer.toString(),
        isNot(contains('noch nicht verfügbar')),
        reason: command,
      );
    }
  });

  test('ohne Befehl kommt die Hilfe und Code 64', () async {
    expect(await run(<String>[]), exitCodeUsage);
    expect(err.toString(), contains('Verwendung:'));
  });

  test('unbekannter Befehl meldet sich und endet mit 64', () async {
    expect(await run(<String>['drucken']), exitCodeUsage);
    expect(err.toString(), contains('Unbekannter Befehl: drucken'));
  });

  test('unbekannte Option endet mit 64 statt Absturz', () async {
    expect(await run(<String>['--gibt-es-nicht']), exitCodeUsage);
    expect(err.toString(), contains('Verwendung:'));
  });

  test('--help endet mit 0 und listet alle Befehle', () async {
    expect(await run(<String>['--help']), 0);
    for (final command in agentCommands) {
      expect(out.toString(), contains(command), reason: command);
    }
  });

  test('pair druckt einen frischen Code und hinterlegt ihn', () async {
    expect(await run(<String>['pair']), 0);

    final code = (await ConfigStore(paths).load()).pairing.code;
    expect(code, matches(RegExp(r'^\d{6}$')));
    expect(out.toString(), contains(code!));
    expect(out.toString(), contains('10 Minuten'));
  });

  /// Wartet, bis [bedingung] gilt (höchstens 10 s). Feste Pausen kippen,
  /// sobald parallel laufende Testdateien den Rechner auslasten.
  Future<void> warteBis(bool Function() bedingung, String was) async {
    final ende = DateTime.now().add(const Duration(seconds: 10));
    while (!bedingung()) {
      if (DateTime.now().isAfter(ende)) fail('$was kam nicht. stderr: $err');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('run startet den Agenten und endet beim Abschaltsignal', () async {
    // Port 0: der Test bekommt einen freien Port vom System.
    final shutdown = Completer<void>();

    final result = run(
      <String>['run'],
      shutdown: () => shutdown.future,
      preferredPort: 0,
    );
    await warteBis(
      () => out.toString().contains('127.0.0.1'),
      'Die Adresse des Agenten',
    );

    shutdown.complete();
    expect(await result, 0);
  });

  // Der Agent ist ein Dauerläufer ohne Aufpasser: stirbt der Prozess, steht die
  // Kasse, und unter Windows startet ihn bis zur nächsten Anmeldung niemand
  // neu. Ein verwaistes Future darf ihn deshalb nicht mitreißen.
  test(
    'ein unbehandelter asynchroner Fehler reißt den Agenten nicht mit',
    () async {
      final shutdown = Completer<void>();
      final result = run(
        <String>['run'],
        // Diese Naht läuft **in** der abgeschirmten Zone: was hier an Fehlern
        // entsteht, entsteht so, wie es auch im Betrieb entstünde.
        shutdown: () async {
          unawaited(Future<void>.error(StateError('Verwaistes Future')));
          await shutdown.future;
        },
        preferredPort: 0,
      );

      await warteBis(
        () => out.toString().contains('127.0.0.1'),
        'Die Adresse des Agenten',
      );

      // Der Agent antwortet weiter — der Prozess lebt, der Server steht.
      final port = int.parse(
        RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(out.toString())!.group(1)!,
      );
      final client = HttpClient();
      final String body;
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/v1/status'),
        )).close();
        body = await response.transform(utf8.decoder).join();
      } finally {
        client.close(force: true);
      }
      expect((jsonDecode(body) as Map)['ok'], isTrue);

      // Und der Fehler steht im Log, statt spurlos verschluckt zu werden.
      final logFile = AgentLog.fileIn(paths.logDirectory);
      await warteBis(
        () =>
            logFile.existsSync() &&
            logFile.readAsStringSync().contains('Verwaistes Future'),
        'Der Fehler im Log',
      );
      final logText = logFile.readAsStringSync();
      expect(logText, contains('Unbehandelter Fehler'));
      expect(logText, contains('Verwaistes Future'));

      shutdown.complete();
      expect(await result, 0);
    },
  );

  group('zertifikat-vertrauen', () {
    // Echte Zertifikate brauchen echtes openssl; ohne wird übersprungen.
    final ohneOpenssl = File(_openssl).existsSync() ? null : 'kein $_openssl';

    late FakeProcessRunner runner;
    late String home;

    setUp(() {
      home = p.join(temp.path, 'home');
      // openssl und chmod laufen echt, `security` ist Attrappe — nie echt.
      runner = FakeProcessRunner()
        ..echt.addAll(<String>{_openssl, 'chmod'})
        ..exitCodes['find-certificate'] = 44
        ..exitCodes['verify-cert'] = 1;
    });

    Future<int> vertrauen({String operatingSystem = 'macos'}) => runCli(
      <String>['zertifikat-vertrauen'],
      out: out,
      err: err,
      paths: paths,
      operatingSystem: operatingSystem,
      environment: <String, String>{'HOME': home},
      runProcess: runner.runner,
    );

    String caPfad() => p.join(temp.path, 'tls', 'ca-cert.pem');

    List<String> security() => runner.calls
        .where((c) => c.executable == _security)
        .map((c) => c.arguments.first)
        .toList();

    test('zertifikat-vertrauen ruft security add-trusted-cert mit genau diesen '
        'Argumenten', () async {
      expect(await vertrauen(), 0, reason: '$err');

      expect(File(caPfad()).existsSync(), isTrue);
      expect(
        runner.sawCall(_security, <String>[
          'add-trusted-cert',
          '-r',
          'trustRoot',
          '-p',
          'ssl',
          '-k',
          p.join(home, 'Library', 'Keychains', 'login.keychain-db'),
          caPfad(),
        ]),
        isTrue,
        reason: runner.lines.join('\n'),
      );
      expect(security(), <String>[
        'verify-cert',
        'find-certificate',
        'verify-cert',
        'add-trusted-cert',
      ]);
      // Vorher sagt der Befehl, dass gleich macOS fragt.
      expect(out.toString(), contains('Touch ID'));
      expect(out.toString(), contains('vertraut'));
      expect(err.toString(), isEmpty);
      // Nur openssl, chmod und security — nichts sonst.
      expect(runner.calls.map((c) => c.executable).toSet(), <String>{
        _openssl,
        'chmod',
        _security,
      });
    }, skip: ohneOpenssl);

    test('schon vertraut: keine Frage, Exitcode 0', () async {
      runner.exitCodes['verify-cert'] = 0;

      expect(await vertrauen(), 0, reason: '$err');
      expect(security(), isNot(contains('add-trusted-cert')));
      expect(out.toString(), contains('bereits'));
      expect(out.toString(), isNot(contains('Touch ID')));
    }, skip: ohneOpenssl);

    test('abgebrochen: Exitcode 70 und der Weg zum Nachholen', () async {
      runner.exitCodes['add-trusted-cert'] = 1;

      expect(await vertrauen(), exitCodeFailed);
      expect(
        err.toString(),
        contains('kasseneck-connect zertifikat-vertrauen'),
      );
    }, skip: ohneOpenssl);

    test('ohne openssl: Exitcode 70, kein security-Aufruf', () async {
      runner.missing.add(_openssl);

      expect(await vertrauen(), exitCodeFailed);
      expect(security(), isEmpty);
      expect(err.toString(), contains('openssl'));
    });

    test('außerhalb von macOS: Hinweis, kein Programmaufruf', () async {
      expect(await vertrauen(operatingSystem: 'windows'), exitCodeFailed);
      expect(runner.calls, isEmpty);
      expect(err.toString(), contains('Mac'));
    });
  });
}
