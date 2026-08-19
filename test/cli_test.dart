import 'dart:async';
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

  Future<int> run(List<String> args, {Future<void> Function()? shutdown}) =>
      runCli(args, out: out, err: err, paths: paths, awaitShutdown: shutdown);

  test('version gibt Name und Version aus', () async {
    expect(await run(<String>['version']), 0);
    expect(out.toString().trim(), '$agentName $agentVersion');
    expect(err.toString(), isEmpty);
  });

  test('--version verhält sich gleich', () async {
    expect(await run(<String>['--version']), 0);
    expect(out.toString().trim(), '$agentName $agentVersion');
  });

  test('noch nicht gebaute Befehle enden mit Code 2', () async {
    for (final command in <String>[
      'install-autostart',
      'uninstall-autostart',
      'doctor',
    ]) {
      final buffer = StringBuffer();
      expect(
        await runCli(
          <String>[command],
          out: StringBuffer(),
          err: buffer,
          paths: paths,
        ),
        exitCodeNotImplemented,
        reason: command,
      );
      expect(
        buffer.toString(),
        contains('noch nicht verfügbar'),
        reason: command,
      );
      expect(buffer.toString(), contains(command), reason: command);
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
    await ConfigStore(paths).save(AgentConfig(port: 0));
    final shutdown = Completer<void>();

    final result = run(<String>['run'], shutdown: () => shutdown.future);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(out.toString(), contains('127.0.0.1'));

    shutdown.complete();
    expect(await result, 0);
  });
}
