import 'dart:async';
import 'dart:convert';

import 'package:kasseneck_connect/src/update/feed.dart';
import 'package:test/test.dart';

const String _sha =
    'd43f99cf91ddbebdd278bebb6db4f9ac33c930a4928e4d73d53cce9f0a1ab4ab';

String _feed({
  String version = '1.4.1',
  String key = 'darwin-arm64',
  String? url,
  String sha256 = _sha,
  Object size = 3516235,
}) => jsonEncode(<String, Object?>{
  'version': version,
  'notes': '',
  'files': <String, Object?>{
    key: <String, Object?>{
      'url':
          url ??
          'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v$version/KasseneckConnect-macos-arm64.pkg',
      'sha256': sha256,
      'size': size,
    },
  },
});

void main() {
  late DateTime now;
  late int calls;
  late List<Uri> requested;

  setUp(() {
    now = DateTime.utc(2026, 11, 2, 6);
    calls = 0;
    requested = <Uri>[];
  });

  UpdateFeed feedWith(Future<String> Function() answer) => UpdateFeed(
    fetch: (uri, timeout) {
      calls++;
      requested.add(uri);
      return answer();
    },
    clock: () => now,
  );

  test('liest Version, Adresse, Prüfsumme und Größe der Plattform', () async {
    final feed = feedWith(() async => _feed());
    final entry = await feed.latest('darwin-arm64');
    expect(entry, isNotNull);
    expect(entry!.version, '1.4.1');
    expect(entry.sha256, _sha);
    expect(entry.size, 3516235);
    expect(
      entry.url.toString(),
      'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.1/KasseneckConnect-macos-arm64.pkg',
    );
    expect(requested.single.toString(), updateFeedUrl);
    expect(
      updateFeedUrl,
      'https://github.com/kreiseck-at/kasseneck-connect/releases/latest/download/latest.json',
    );
  });

  test('innerhalb von 6 Stunden kein zweiter Abruf, danach schon', () async {
    final feed = feedWith(() async => _feed());
    await feed.latest('darwin-arm64');
    now = now.add(const Duration(hours: 5, minutes: 59));
    await feed.latest('darwin-arm64');
    expect(calls, 1);
    now = now.add(const Duration(minutes: 2));
    await feed.latest('darwin-arm64');
    expect(calls, 2);
  });

  test(
    'hängt der Abruf, kehrt latest nach dem Zeitbudget mit null zurück',
    () async {
      final never = Completer<String>();
      final feed = UpdateFeed(
        fetch: (uri, timeout) => never.future,
        clock: () => now,
        budget: const Duration(milliseconds: 50),
      );
      final watch = Stopwatch()..start();
      expect(await feed.latest('darwin-arm64'), isNull);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    },
  );

  test('hängt ein späterer Abruf, gilt der letzte bekannte Stand', () async {
    var hang = false;
    final never = Completer<String>();
    final feed = UpdateFeed(
      fetch: (uri, timeout) => hang ? never.future : Future.value(_feed()),
      clock: () => now,
      budget: const Duration(milliseconds: 50),
    );
    await feed.latest('darwin-arm64');
    hang = true;
    now = now.add(const Duration(hours: 7));
    expect((await feed.latest('darwin-arm64'))?.version, '1.4.1');
  });

  test('ein laufender Abruf wird geteilt', () async {
    final pending = Completer<String>();
    final feed = feedWith(() => pending.future);
    final a = feed.latest('darwin-arm64');
    final b = feed.latest('darwin-arm64');
    pending.complete(_feed());
    await Future.wait(<Future<Object?>>[a, b]);
    expect(calls, 1);
  });

  test(
    'nach einem Fehler höchstens alle 10 Minuten ein neuer Versuch',
    () async {
      var fail = true;
      final feed = feedWith(
        () async => fail ? throw const FormatException('weg') : _feed(),
      );
      expect(await feed.latest('darwin-arm64'), isNull);
      now = now.add(const Duration(minutes: 9));
      expect(await feed.latest('darwin-arm64'), isNull);
      expect(calls, 1);
      fail = false;
      now = now.add(const Duration(minutes: 2));
      expect((await feed.latest('darwin-arm64'))?.version, '1.4.1');
      expect(calls, 2);
    },
  );

  group('verwirft, was nicht genau unser Paket ist', () {
    final cases = <String, String>{
      'fremder Host': _feed(
        url:
            'https://example.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.1/KasseneckConnect-macos-arm64.pkg',
      ),
      'http': _feed(
        url:
            'http://github.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.1/KasseneckConnect-macos-arm64.pkg',
      ),
      'fremdes Repo': _feed(
        url:
            'https://github.com/andere/kasseneck-connect/releases/download/v1.4.1/KasseneckConnect-macos-arm64.pkg',
      ),
      'falscher Name': _feed(
        url:
            'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.1/Anderes.pkg',
      ),
      'Tag passt nicht zur Version': _feed(
        url:
            'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.0/KasseneckConnect-macos-arm64.pkg',
      ),
      'Prüfsumme kein Hex': _feed(sha256: 'z' * 64),
      'Prüfsumme zu kurz': _feed(sha256: 'ab'),
      'Größe keine Zahl': _feed(size: '3516235'),
      'Größe null': _feed(size: 0),
      'Version kaputt': _feed(version: '1.4'),
      'andere Plattform': _feed(key: 'windows-x64'),
      'kein JSON': 'nicht json',
      'leeres Objekt': '{}',
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final feed = feedWith(() async => entry.value);
        expect(await feed.latest('darwin-arm64'), isNull);
      });
    }
  });

  test('unbekannter Plattformschlüssel ergibt null', () async {
    final feed = feedWith(() async => _feed());
    expect(await feed.latest('amiga-68k'), isNull);
  });
}
