import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../downloads.dart';
import 'semver.dart';

/// Adresse von `latest.json` im jeweils neuesten Release (siehe
/// `tool/release.sh`).
const String updateFeedUrl = '${downloadBaseUrl}latest.json';

/// Holt den Text unter [uri] und gibt höchstens [timeout] lang Zeit. In Tests
/// austauschbar.
typedef FeedFetch = Future<String> Function(Uri uri, Duration timeout);

/// Ein Eintrag aus `latest.json`: die neueste Version für eine Plattform.
class FeedEntry {
  const FeedEntry({
    required this.version,
    required this.url,
    required this.sha256,
    required this.size,
  });

  final String version;
  final Uri url;

  /// SHA-256 der Datei, 64 Zeichen klein geschrieben.
  final String sha256;

  /// Größe in Byte.
  final int size;
}

/// Die neueste veröffentlichte Version, aus `latest.json`.
///
/// Fragt GitHub höchstens alle [maxAge] (nach einem Fehler höchstens alle
/// [retryAfterFailure]); ein laufender Abruf wird geteilt. [latest] wartet
/// höchstens [budget] darauf und nimmt sonst den letzten bekannten Stand –
/// die Kasse soll nie auf GitHub warten, wenn der Rechner es nicht erreicht.
///
/// Was nicht genau auf unser Release zeigt (Host, Repo, Tag, fester Name),
/// zählt nicht: ein verbogener Feed führt so nie zu einem fremden Download.
class UpdateFeed {
  UpdateFeed({
    required FeedFetch fetch,
    DateTime Function()? clock,
    this.maxAge = const Duration(hours: 6),
    this.budget = const Duration(seconds: 1),
    this.retryAfterFailure = const Duration(minutes: 10),
  }) : _fetch = fetch,
       _clock = clock ?? DateTime.now;

  final FeedFetch _fetch;
  final DateTime Function() _clock;
  final Duration maxAge;
  final Duration budget;
  final Duration retryAfterFailure;

  Map<String, Object?>? _files;
  String? _version;
  DateTime? _fetchedAt;
  DateTime? _failedAt;
  Future<void>? _running;

  /// Die neueste Version für [platformKey] (Schlüssel wie in
  /// [downloadLatestNames]) oder `null`, wenn unbekannt oder ungültig.
  Future<FeedEntry?> latest(String platformKey) async {
    if (_stale()) {
      final running = _running ??= _refresh().whenComplete(
        () => _running = null,
      );
      try {
        await running.timeout(budget);
      } on TimeoutException {
        // Weiter mit dem letzten bekannten Stand; der Abruf läuft weiter.
      }
    }
    return _entry(platformKey);
  }

  /// Der zuletzt abgerufene Stand für [platformKey] – ohne Abruf (Diagnose).
  FeedEntry? gemerkt(String platformKey) => _entry(platformKey);

  bool _stale() {
    final now = _clock();
    final failed = _failedAt;
    if (failed != null && now.difference(failed) < retryAfterFailure) {
      return false;
    }
    final fetched = _fetchedAt;
    return fetched == null || now.difference(fetched) >= maxAge;
  }

  Future<void> _refresh() async {
    try {
      final text = await _fetch(
        Uri.parse(updateFeedUrl),
        const Duration(seconds: 10),
      );
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) {
        throw const FormatException('kein Objekt');
      }
      final version = json['version'];
      final files = json['files'];
      if (version is! String || files is! Map<String, Object?>) {
        throw const FormatException('version oder files fehlt');
      }
      compareVersions(version, version);
      _version = version;
      _files = files;
      _fetchedAt = _clock();
      _failedAt = null;
    } on Object {
      _failedAt = _clock();
    }
  }

  FeedEntry? _entry(String platformKey) {
    final version = _version;
    final name = downloadLatestNames[platformKey];
    final raw = _files?[platformKey];
    if (version == null || name == null || raw is! Map<String, Object?>) {
      return null;
    }
    final url = raw['url'];
    final sha256 = raw['sha256'];
    final size = raw['size'];
    if (url is! String || sha256 is! String || size is! int || size <= 0) {
      return null;
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) return null;
    final expected = Uri.parse(
      'https://github.com/kreiseck-at/kasseneck-connect/releases/download/'
      'v$version/$name',
    );
    final uri = Uri.tryParse(url);
    if (uri == null || uri != expected) return null;
    return FeedEntry(version: version, url: uri, sha256: sha256, size: size);
  }
}

/// Echter Abruf über HTTPS (nur HTTPS, folgt Weiterleitungen von GitHub).
FeedFetch httpFeedFetch() => (uri, timeout) async {
  if (uri.scheme != 'https') {
    throw ArgumentError.value(uri, 'uri', 'nur https');
  }
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return await response.transform(utf8.decoder).join().timeout(timeout);
  } finally {
    client.close(force: true);
  }
};
