import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

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

  test('run startet den Agenten und endet beim Abschaltsignal', () async {
    // Port 0: der Test bekommt einen freien Port vom System.
    final shutdown = Completer<void>();

    final result = run(
      <String>['run'],
      shutdown: () => shutdown.future,
      preferredPort: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(out.toString(), contains('127.0.0.1'));

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

      await Future<void>.delayed(const Duration(milliseconds: 300));

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
      final logText = AgentLog.fileIn(paths.logDirectory).readAsStringSync();
      expect(logText, contains('Unbehandelter Fehler'));
      expect(logText, contains('Verwaistes Future'));

      shutdown.complete();
      expect(await result, 0);
    },
  );
}
