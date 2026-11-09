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

  group('kaputte config.json geht nie verloren', () {
    // Fester Zeitpunkt für die Namen der aufbewahrten Fassungen.
    final zeitpunkt = DateTime.utc(2026, 11, 9, 6, 15, 30);
    const kaputt = '{"port": 27183, "tokenHashes": ["hash-a"';
    late AgentLog log;
    late ConfigStore store;

    setUp(() {
      log = AgentLog(Directory(p.join(temp.path, 'logs')));
      store = ConfigStore.forDirectory(temp, log: log, clock: () => zeitpunkt);
    });

    List<File> defekte() =>
        temp
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('config.json.defekt-'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    File sicherung() => File(p.join(temp.path, 'config.json.bak'));

    int rechte(File f) => f.statSync().mode & 0x1FF;

    AgentConfig mitDruckerUndToken(String token) => AgentConfig(
      tokenHashes: <String>[token],
      printers: <PrinterConfig>[
        PrinterConfig(
          id: 'p1',
          name: 'Kasse',
          kind: PrinterKind.tcp9100,
          host: '192.168.0.50',
        ),
      ],
    );

    test('jedes Speichern hält die vorige gute Fassung als .bak', () async {
      await store.save(mitDruckerUndToken('hash-a'));
      expect(sicherung().existsSync(), isFalse, reason: 'vorher gab es nichts');
      final vorher = store.file.readAsBytesSync();

      await store.save(mitDruckerUndToken('hash-b'));

      expect(sicherung().readAsBytesSync(), vorher);
      expect((await store.load()).tokenHashes, <String>['hash-b']);
      if (!Platform.isWindows) expect(rechte(sicherung()), 0x180);
    });

    test('kaputt mit Sicherung: die Sicherung springt ein, die kaputte Datei '
        'bleibt als .defekt-<UTC> erhalten', () async {
      await store.save(mitDruckerUndToken('hash-a'));
      await store.save(mitDruckerUndToken('hash-b'));
      final sicherungVorher = sicherung().readAsBytesSync();
      store.file.writeAsStringSync(kaputt);

      final config = await store.load();

      // Die Sicherung ist die Fassung vor der letzten (hash-a).
      expect(config.tokenHashes, <String>['hash-a']);
      expect(config.printers.single.host, '192.168.0.50');
      final abgelegt = defekte().single;
      expect(p.basename(abgelegt.path), 'config.json.defekt-20261109T061530Z');
      expect(abgelegt.readAsStringSync(), kaputt);
      // load() schreibt die config.json nie.
      expect(store.file.readAsStringSync(), kaputt);
      expect(
        log.recentErrors.map((e) => e.message).join('\n'),
        allOf(
          contains('config.json ist unbrauchbar'),
          contains('config.json.defekt-20261109T061530Z'),
          contains('config.json.bak'),
        ),
      );

      // Das nächste mutate baut auf der Sicherung auf …
      final neu = await store.mutate(
        (c) => c.copyWith(tokenHashes: <String>[...c.tokenHashes, 'hash-c']),
      );
      expect(neu.tokenHashes, <String>['hash-a', 'hash-c']);
      expect(neu.printers, hasLength(1));
      expect(
        (await ConfigStore.forDirectory(temp).load()).tokenHashes,
        <String>['hash-a', 'hash-c'],
      );
      // … die kaputte Fassung landet nicht in der Sicherung …
      expect(sicherung().readAsBytesSync(), sicherungVorher);
      // … und wird nicht ein zweites Mal abgelegt.
      expect(defekte(), hasLength(1));
    });

    test('kaputt ohne Sicherung: Standardkonfiguration, aber nichts wird '
        'still überschrieben', () async {
      temp.createSync(recursive: true);
      store.file.writeAsStringSync(kaputt);

      final config = await store.load();
      expect(config.tokenHashes, isEmpty);
      expect(config.port, 27182);
      expect(
        log.recentErrors.map((e) => e.message).join('\n'),
        contains('keine brauchbare Sicherung'),
      );

      await store.mutate((c) => c.copyWith(tokenHashes: <String>['hash-neu']));

      // Der alte Inhalt liegt vollständig daneben.
      expect(defekte().single.readAsStringSync(), kaputt);
      expect((await store.load()).tokenHashes, <String>['hash-neu']);
      // Eine kaputte Fassung wird nie zur Sicherung.
      expect(sicherung().existsSync(), isFalse);
    });

    test(
      'leere Datei: zählt als unbrauchbar, die Sicherung springt ein',
      () async {
        await store.save(mitDruckerUndToken('hash-a'));
        await store.save(mitDruckerUndToken('hash-b'));
        store.file.writeAsStringSync('');

        expect((await store.load()).tokenHashes, <String>['hash-a']);
        expect(defekte().single.lengthSync(), 0);
      },
    );

    test(
      'Erststart: keine Datei, keine Sicherung – still und ohne Ablage',
      () async {
        final config = await store.load();

        expect(config.tokenHashes, isEmpty);
        expect(defekte(), isEmpty);
        expect(log.recentErrors, isEmpty);
        expect(log.file.existsSync(), isFalse, reason: 'nichts zu melden');
      },
    );

    test('fehlt die config.json, aber die Sicherung nicht, gilt die '
        'Sicherung (mit Warnung)', () async {
      await store.save(mitDruckerUndToken('hash-a'));
      await store.save(mitDruckerUndToken('hash-b'));
      store.file.deleteSync();

      expect((await store.load()).tokenHashes, <String>['hash-a']);
      expect(log.file.readAsStringSync(), contains('config.json fehlt'));
    });

    test('viele Leser, auch aus einem zweiten Prozess: genau eine Ablage und '
        'eine Meldung', () async {
      await store.save(mitDruckerUndToken('hash-a'));
      await store.save(mitDruckerUndToken('hash-b'));
      store.file.writeAsStringSync(kaputt);

      // Wie Anfragen an den Agenten: load() läuft bei jeder.
      await Future.wait(<Future<AgentConfig>>[
        for (var i = 0; i < 10; i++) store.load(),
      ]);
      await store.load();
      // Ein zweiter Prozess (etwa `pair`) hat sein eigenes Gedächtnis.
      final anderer = ConfigStore.forDirectory(
        temp,
        clock: () => zeitpunkt.add(const Duration(seconds: 5)),
      );
      await anderer.load();

      expect(defekte(), hasLength(1));
      final ablage = log.recentErrors.where(
        (e) => e.message.contains('aufbewahrt als'),
      );
      expect(ablage, hasLength(1));
    });

    test('zwei verschiedene kaputte Fassungen in derselben Sekunde: zwei '
        'Ablagen', () async {
      temp.createSync(recursive: true);
      store.file.writeAsStringSync('{eins');
      await store.load();
      store.file.writeAsStringSync('{zwei');
      await store.load();

      expect(defekte().map((f) => p.basename(f.path)), <String>[
        'config.json.defekt-20261109T061530Z',
        'config.json.defekt-20261109T061530Z-2',
      ]);
      expect(defekte().map((f) => f.readAsStringSync()), <String>[
        '{eins',
        '{zwei',
      ]);
    });

    test(
      'Sicherung und Ablage sind nur für den Besitzer lesbar (600)',
      () async {
        if (Platform.isWindows) return;
        await store.save(mitDruckerUndToken('hash-a'));
        await store.save(mitDruckerUndToken('hash-b'));
        store.file.writeAsStringSync(kaputt);
        // Wie eine von Hand angelegte Datei: Standardrechte.
        Process.runSync('chmod', <String>['644', store.file.path]);
        await store.load();

        expect(rechte(sicherung()), 0x180);
        expect(rechte(defekte().single), 0x180);
      },
    );

    test('nicht lesbare config.json: Sicherung beim Lesen, beim Speichern '
        'beiseitegestellt statt überschrieben', () async {
      if (Platform.isWindows) return;
      final ichBinRoot =
          '${Process.runSync('id', <String>['-u']).stdout}'.trim() == '0';
      if (ichBinRoot) return; // root liest auch Dateien ohne Rechte.
      await store.save(mitDruckerUndToken('hash-a'));
      await store.save(mitDruckerUndToken('hash-b'));
      final inhalt = store.file.readAsStringSync();
      Process.runSync('chmod', <String>['000', store.file.path]);

      expect((await store.load()).tokenHashes, <String>['hash-a']);

      await store.mutate(
        (c) => c.copyWith(tokenHashes: <String>[...c.tokenHashes, 'hash-c']),
      );

      final abgelegt = defekte().single;
      Process.runSync('chmod', <String>['600', abgelegt.path]);
      expect(abgelegt.readAsStringSync(), inhalt);
      expect((await store.load()).tokenHashes, <String>['hash-a', 'hash-c']);
    });
  });
}
