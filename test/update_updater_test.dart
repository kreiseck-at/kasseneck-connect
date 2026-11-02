import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/src/events/bus.dart';
import 'package:kasseneck_connect/src/update/feed.dart';
import 'package:kasseneck_connect/src/update/updater.dart';
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

String _fixture(String name) =>
    File('test/fixtures/update/$name').readAsStringSync();

void main() {
  late Directory cache;
  late EventBus bus;
  late List<AgentEvent> events;
  late FakeProcessRunner run;
  late List<int> paket;
  late DateTime now;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('connect-update-');
    addTearDown(() => cache.delete(recursive: true));
    bus = EventBus();
    events = <AgentEvent>[];
    final sub = bus.stream.listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await bus.close();
    });
    now = DateTime.utc(2026, 11, 2, 6);
    paket = utf8.encode('xar! Testpaket 1.4.1');
    run = FakeProcessRunner()
      ..antwort = (executable, arguments) async => switch (executable) {
        'pkgutil' => ProcessResult(
          1,
          0,
          _fixture('pkgutil-check-signature-1.3.0.txt'),
          '',
        ),
        'spctl' => ProcessResult(2, 0, '', _fixture('spctl-install-1.3.0.txt')),
        _ => null,
      };
  });

  String feedJson({
    String version = '1.4.1',
    String? sha,
    int? size,
  }) => jsonEncode(<String, Object?>{
    'version': version,
    'files': <String, Object?>{
      'darwin-arm64': <String, Object?>{
        'url':
            'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v$version/KasseneckConnect-macos-arm64.pkg',
        'sha256': sha ?? sha256.convert(paket).toString(),
        'size': size ?? paket.length,
      },
    },
  });

  ConnectUpdater updater({
    String feed = '',
    String current = '1.4.0',
    String os = 'macos',
    Downloader? download,
  }) => ConnectUpdater(
    feed: UpdateFeed(
      fetch: (uri, timeout) async => feed.isEmpty ? feedJson() : feed,
      clock: () => now,
    ),
    download:
        download ??
        (url, target, onProgress) async {
          await target.writeAsBytes(paket);
          onProgress(paket.length ~/ 2, paket.length);
          onProgress(paket.length, paket.length);
        },
    run: run.runner,
    events: bus,
    cacheDir: cache,
    platformKey: 'darwin-arm64',
    current: current,
    operatingSystem: os,
    clock: () => now,
  );

  Future<void> settle(ConnectUpdater u) async {
    await u.running;
    await Future<void>.delayed(Duration.zero);
  }

  List<String> types() => events.map((e) => e.type).toList();

  test('info: neuere Version, Ein-Klick am Mac', () async {
    final info = await updater().info();
    expect(info.toJson(), <String, Object?>{
      'current': '1.4.0',
      'latest': '1.4.1',
      'available': true,
      'platform': 'darwin-arm64',
      'size': paket.length,
      'oneClick': true,
      'progress': null,
      'lastError': null,
    });
  });

  test(
    'Erfolg: laden, prüfen, Neustart ankündigen, Installer öffnen',
    () async {
      final u = updater();
      await u.start();
      await settle(u);
      final phases = events
          .where((e) => e.type == eventUpdateProgress)
          .map((e) => e.data['phase'])
          .toList();
      expect(phases.first, 'download');
      expect(
        phases,
        containsAllInOrder(<String>['download', 'check', 'ready']),
      );
      expect(types().last, eventAgentRestarting);
      expect(events.last.data, <String, Object?>{
        'reason': 'update',
        'version': '1.4.1',
      });
      final open = run.calls.where((c) => c.executable == 'open').single;
      expect(File(open.arguments.single).existsSync(), isTrue);
      expect(open.arguments.single, startsWith(cache.path));
      expect(types(), isNot(contains(eventUpdateFailed)));
      expect(u.busy, isFalse);
    },
  );

  test('falsche Prüfsumme: Fehler, Datei weg, kein open', () async {
    final u = updater(feed: feedJson(sha: '0' * 64));
    await u.start();
    await settle(u);
    expect(events.last.type, eventUpdateFailed);
    expect(events.last.data['code'], 'update_checksum_mismatch');
    expect(run.calls.where((c) => c.executable == 'open'), isEmpty);
    expect(cache.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('falsche Größe: Fehler wie bei der Prüfsumme', () async {
    final u = updater(feed: feedJson(size: 99));
    await u.start();
    await settle(u);
    expect(events.last.data['code'], 'update_checksum_mismatch');
  });

  test('Signatur ungültig: Fehler, kein open', () async {
    run.antwort = (executable, arguments) async => executable == 'pkgutil'
        ? ProcessResult(1, 1, '', 'no signature')
        : null;
    final u = updater();
    await u.start();
    await settle(u);
    expect(events.last.data['code'], 'update_signature_invalid');
    expect(run.calls.where((c) => c.executable == 'open'), isEmpty);
  });

  test('Download scheitert: update_download_failed', () async {
    final u = updater(
      download: (url, target, onProgress) async =>
          throw const HttpException('weg'),
    );
    await u.start();
    await settle(u);
    expect(events.last.data['code'], 'update_download_failed');
  });

  test('open scheitert: update_open_failed', () async {
    final vorher = run.antwort!;
    run.antwort = (executable, arguments) async => executable == 'open'
        ? ProcessResult(3, 1, '', 'kaputt')
        : vorher(executable, arguments);
    final u = updater();
    await u.start();
    await settle(u);
    expect(events.last.data['code'], 'update_open_failed');
  });

  test('gleiche Version: start lehnt mit update_not_available ab', () async {
    final u = updater(current: '1.4.1');
    expect(
      u.start,
      throwsA(
        isA<UpdateFailure>().having(
          (f) => f.code,
          'code',
          'update_not_available',
        ),
      ),
    );
    expect((await u.info()).available, isFalse);
  });

  test('zweiter Start während des ersten: update_busy', () async {
    final hold = Completer<void>();
    final u = updater(
      download: (url, target, onProgress) async {
        await hold.future;
        await target.writeAsBytes(paket);
      },
    );
    await u.start();
    expect(u.busy, isTrue);
    await expectLater(
      u.start,
      throwsA(
        isA<UpdateFailure>().having((f) => f.code, 'code', 'update_busy'),
      ),
    );
    hold.complete();
    await settle(u);
  });

  test('Windows und Linux: kein Ein-Klick, start lehnt ab', () async {
    for (final os in <String>['windows', 'linux']) {
      final u = updater(os: os);
      expect((await u.info()).oneClick, isFalse);
      await expectLater(
        u.start,
        throwsA(
          isA<UpdateFailure>().having(
            (f) => f.code,
            'code',
            'update_unsupported',
          ),
        ),
      );
    }
  });

  test('ohne erreichbaren Feed: nichts verfügbar, kein Fehler', () async {
    final u = ConnectUpdater(
      feed: UpdateFeed(
        fetch: (uri, timeout) async => throw const SocketException('offline'),
        clock: () => now,
      ),
      download: (url, target, onProgress) async {},
      run: run.runner,
      events: bus,
      cacheDir: cache,
      platformKey: 'darwin-arm64',
      current: '1.4.0',
      operatingSystem: 'macos',
      clock: () => now,
    );
    final info = await u.info();
    expect(info.latest, isNull);
    expect(info.available, isFalse);
  });

  test('info zeigt den Fortschritt während der Aktualisierung', () async {
    final hold = Completer<void>();
    final u = updater(
      download: (url, target, onProgress) async {
        onProgress(paket.length ~/ 2, paket.length);
        await hold.future;
        await target.writeAsBytes(paket);
      },
    );
    expect((await u.info()).toJson()['progress'], isNull);
    await u.start();
    // Das Anlegen des Ordners ist echtes Datei-IO: warten, bis der Download läuft.
    for (
      var i = 0;
      i < 100 && (await u.info()).progress?['percent'] != 50;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final laufend = (await u.info()).toJson();
    expect(laufend['progress'], <String, Object?>{
      'version': '1.4.1',
      'phase': 'download',
      'percent': 50,
    });
    hold.complete();
    await settle(u);
    expect((await u.info()).toJson()['progress'], <String, Object?>{
      'version': '1.4.1',
      'phase': 'ready',
      'percent': 100,
    });
    expect((await u.info()).toJson()['lastError'], isNull);
  });

  test(
    'info nennt den letzten Fehler, bis die nächste Aktualisierung startet',
    () async {
      final u = updater(feed: feedJson(sha: '0' * 64));
      await u.start();
      await settle(u);
      final nachher = (await u.info()).toJson();
      expect(nachher['progress'], isNull);
      expect((nachher['lastError'] as Map)['code'], 'update_checksum_mismatch');
    },
  );

  test('cleanup löscht Pakete älter als 24 Stunden', () async {
    final alt = File('${cache.path}/alt.pkg')..writeAsStringSync('x');
    alt.setLastModifiedSync(now.subtract(const Duration(hours: 25)));
    final neu = File('${cache.path}/neu.pkg')..writeAsStringSync('y');
    neu.setLastModifiedSync(now.subtract(const Duration(hours: 1)));
    await updater().cleanup();
    expect(alt.existsSync(), isFalse);
    expect(neu.existsSync(), isTrue);
  });
}
