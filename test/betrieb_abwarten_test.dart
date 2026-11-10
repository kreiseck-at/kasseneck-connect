import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('connect-abwarten-'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<(int, String)> lauf() async {
    final out = StringBuffer();
    final code = await runCli(
      <String>['betrieb-abwarten'],
      out: out,
      err: StringBuffer(),
      paths: ConfigPaths(temp),
    );
    return (code, out.toString());
  }

  test('ohne betrieb.lock: sofort, still, Exit 0', () async {
    final uhr = Stopwatch()..start();
    final (code, text) = await lauf();
    expect(code, 0);
    expect(text, isEmpty);
    expect(uhr.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('verwaiste betrieb.lock (älter als 6 min): sofort weiter', () async {
    betriebLockDatei(temp)
      ..writeAsStringSync('{}')
      ..setLastModifiedSync(
        DateTime.now().subtract(betriebLockFrisch + const Duration(minutes: 1)),
      );
    final uhr = Stopwatch()..start();
    expect((await lauf()).$1, 0);
    expect(uhr.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('frische betrieb.lock: wartet, bis sie weg ist', () async {
    final datei = betriebLockDatei(temp)..writeAsStringSync('{}');
    final ergebnis = lauf();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    datei.deleteSync();
    final (code, text) = await ergebnis;
    expect(code, 0);
    expect(text, contains('gewartet'));
  });

  test('das postinstall wartet vor dem Neustart des Agenten', () {
    final skript = File(
      p.join('tool', 'pkg', 'macos', 'build_pkg.sh'),
    ).readAsStringSync();
    final warten = skript.indexOf('"\$BINARY" betrieb-abwarten || true');
    final neustart = skript.indexOf('"\$BINARY" install-autostart');
    expect(warten, greaterThan(0));
    expect(warten, lessThan(neustart));
  });
}
