@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('connect-race-'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('Temp-Dateien zweier Schreibvorgänge heißen unterschiedlich', () {
    final paths = ConfigPaths(temp);
    final names = <String>{
      for (var i = 0; i < 20; i++) p.basename(paths.configTempFile().path),
    };
    expect(names, hasLength(20));
    expect(names.first, startsWith('config.json.$pid.'));
  });

  test('zwei Prozesse mutieren dieselbe Datei ohne Verlust', () async {
    final worker = p.join(
      Directory.current.path,
      'test',
      'support',
      'mutate_worker.dart',
    );

    Future<ProcessResult> spawn(String prefix) => Process.run(
      Platform.resolvedExecutable,
      <String>['run', worker, temp.path, prefix, '50'],
      workingDirectory: Directory.current.path,
    );

    final results = await Future.wait(<Future<ProcessResult>>[
      spawn('a'),
      spawn('b'),
    ]);

    for (final result in results) {
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }

    final config = await ConfigStore.forDirectory(temp).load();
    expect(config.tokenHashes, hasLength(100));
    expect(config.tokenHashes.toSet(), hasLength(100));

    // Keine liegen gebliebenen Temp-Dateien.
    final leftovers = temp
        .listSync()
        .whereType<File>()
        .map((file) => p.basename(file.path))
        .where((name) => name.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('zwei Prozesse auf einer kaputten config.json: die Sicherung trägt, '
      'die kaputte Fassung liegt genau einmal daneben', () async {
    final store = ConfigStore.forDirectory(temp);
    await store.save(AgentConfig(tokenHashes: <String>['alt-1']));
    await store.save(AgentConfig(tokenHashes: <String>['alt-2']));
    const kaputt = '{"tokenHashes": ["alt-2"';
    store.file.writeAsStringSync(kaputt);

    final worker = p.join(
      Directory.current.path,
      'test',
      'support',
      'mutate_worker.dart',
    );
    Future<ProcessResult> spawn(String prefix) => Process.run(
      Platform.resolvedExecutable,
      <String>['run', worker, temp.path, prefix, '20'],
      workingDirectory: Directory.current.path,
    );
    final results = await Future.wait(<Future<ProcessResult>>[
      spawn('a'),
      spawn('b'),
    ]);
    for (final result in results) {
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }

    final config = await ConfigStore.forDirectory(temp).load();
    // Aufgebaut auf der Sicherung (alt-1), keine Änderung verloren.
    expect(config.tokenHashes.first, 'alt-1');
    expect(config.tokenHashes, hasLength(41));
    final defekte = temp
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('config.json.defekt-'))
        .toList();
    expect(defekte, hasLength(1));
    expect(defekte.single.readAsStringSync(), kaputt);
  });
}
