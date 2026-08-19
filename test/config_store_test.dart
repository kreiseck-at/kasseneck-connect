import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('connect-store-'));
  tearDown(() => temp.deleteSync(recursive: true));

  ConfigStore storeIn(Directory dir) => ConfigStore.forDirectory(dir);

  test('fehlende Datei ergibt die Standardkonfiguration', () async {
    final config = await storeIn(temp).load();
    expect(config.port, 27182);
    expect(config.tokenHashes, isEmpty);
  });

  test('save/load-Roundtrip', () async {
    final store = storeIn(temp);
    final original = AgentConfig(
      port: 27186,
      tokenHashes: <String>['hash-1'],
      printers: <PrinterConfig>[
        PrinterConfig(
          id: 'p1',
          name: 'Kasse',
          kind: PrinterKind.epos,
          host: '10.0.0.7',
        ),
      ],
      terminal: TerminalConfig(host: '10.0.0.8'),
    );

    await store.save(original);
    final loaded = await store.load();

    expect(loaded.port, 27186);
    expect(loaded.tokenHashes, <String>['hash-1']);
    expect(loaded.printers.single.kind, PrinterKind.epos);
    expect(loaded.printers.single.port, 80);
    expect(loaded.terminal?.host, '10.0.0.8');
  });

  test('Schreiben ist atomar — keine Temp-Datei bleibt liegen', () async {
    final store = storeIn(temp);
    await store.save(AgentConfig());
    await store.save(AgentConfig(port: 27187));

    expect(store.file.existsSync(), isTrue);
    expect(File(p.join(temp.path, 'config.json.tmp')).existsSync(), isFalse);
    expect((await store.load()).port, 27187);
  });

  test('legt fehlendes Verzeichnis an', () async {
    final nested = Directory(p.join(temp.path, 'a', 'b'));
    final store = storeIn(nested);
    await store.save(AgentConfig(port: 27188));

    expect(nested.existsSync(), isTrue);
    expect((await store.load()).port, 27188);
  });

  test('Datei ist nur für den Besitzer lesbar (600)', () async {
    if (Platform.isWindows) return;
    final store = storeIn(temp);
    await store.save(AgentConfig(tokenHashes: <String>['geheim-hash']));

    final mode = store.file.statSync().mode & 0x1FF;
    expect(mode, 0x180, reason: 'erwartet 0600, war ${mode.toRadixString(8)}');
  });

  test('kaputte Datei blockiert den Start nicht', () async {
    final store = storeIn(temp);
    temp.createSync(recursive: true);
    store.file.writeAsStringSync('{kein json');

    final config = await store.load();
    expect(config.port, 27182);
  });

  test('leere Datei ergibt die Standardkonfiguration', () async {
    final store = storeIn(temp);
    store.file.writeAsStringSync('\n');
    expect((await store.load()).port, 27182);
  });

  test('ein misslungenes Speichern lässt keine .tmp-Datei liegen', () async {
    final store = storeIn(temp);
    // `config.json` als Verzeichnis: das Umbenennen muss scheitern.
    Directory(store.file.path).createSync(recursive: true);

    await expectLater(
      store.save(AgentConfig()),
      throwsA(isA<FileSystemException>()),
    );

    final leftovers = temp.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.tmp'),
    );
    expect(leftovers, isEmpty);
  });
}
