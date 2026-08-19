import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
  });

  int run(List<String> args) => runCli(args, out: out, err: err);

  test('version gibt Name und Version aus', () {
    expect(run(<String>['version']), 0);
    expect(out.toString().trim(), '$agentName $agentVersion');
    expect(err.toString(), isEmpty);
  });

  test('--version verhält sich gleich', () {
    expect(run(<String>['--version']), 0);
    expect(out.toString().trim(), '$agentName $agentVersion');
  });

  test('noch nicht gebaute Befehle enden mit Code 2', () {
    for (final command in <String>[
      'run',
      'pair',
      'install-autostart',
      'uninstall-autostart',
      'doctor',
    ]) {
      final buffer = StringBuffer();
      expect(
        runCli(<String>[command], out: StringBuffer(), err: buffer),
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

  test('ohne Befehl kommt die Hilfe und Code 64', () {
    expect(run(<String>[]), exitCodeUsage);
    expect(err.toString(), contains('Verwendung:'));
  });

  test('unbekannter Befehl meldet sich und endet mit 64', () {
    expect(run(<String>['drucken']), exitCodeUsage);
    expect(err.toString(), contains('Unbekannter Befehl: drucken'));
  });

  test('unbekannte Option endet mit 64 statt Absturz', () {
    expect(run(<String>['--gibt-es-nicht']), exitCodeUsage);
    expect(err.toString(), contains('Verwendung:'));
  });

  test('--help endet mit 0 und listet alle Befehle', () {
    expect(run(<String>['--help']), 0);
    for (final command in agentCommands) {
      expect(out.toString(), contains(command), reason: command);
    }
  });
}
