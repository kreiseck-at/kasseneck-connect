import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../events/bus.dart';
import '../process_runner.dart';
import '../version.dart';
import 'feed.dart';
import 'mac_package.dart';
import 'semver.dart';

/// Fehlercodes der Aktualisierung (Antwort von `POST /v1/update` bzw.
/// Ereignis `update.failed`).
const String errorUpdateUnsupported = 'update_unsupported';
const String errorUpdateNotAvailable = 'update_not_available';
const String errorUpdateBusy = 'update_busy';
const String errorUpdateDownloadFailed = 'update_download_failed';
const String errorUpdateChecksumMismatch = 'update_checksum_mismatch';
const String errorUpdateSignatureInvalid = 'update_signature_invalid';
const String errorUpdateNotNewer = 'update_not_newer';
const String errorUpdateOpenFailed = 'update_open_failed';

/// So lange bleibt ein geladenes Paket liegen, bevor [ConnectUpdater.cleanup]
/// es entfernt.
const Duration _keepDownloads = Duration(hours: 24);

/// Hosts, auf die ein Download weiterleiten darf (GitHub legt Release-Assets
/// auf eigene Download-Hosts).
const Set<String> updateDownloadHosts = <String>{
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
};

/// Lädt [url] nach [target] und meldet den Fortschritt. In Tests austauschbar.
typedef Downloader =
    Future<void> Function(
      Uri url,
      File target,
      void Function(int received, int? total) onProgress,
    );

/// Eine abgelehnte Aktualisierung (synchron bei `start`).
class UpdateFailure implements Exception {
  const UpdateFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Stand für `GET /v1/update`.
class UpdateInfo {
  const UpdateInfo({
    required this.current,
    required this.latest,
    required this.available,
    required this.platform,
    required this.size,
    required this.oneClick,
  });

  final String current;
  final String? latest;
  final bool available;
  final String platform;
  final int? size;
  final bool oneClick;

  Map<String, Object?> toJson() => <String, Object?>{
    'current': current,
    'latest': latest,
    'available': available,
    'platform': platform,
    'size': size,
    'oneClick': oneClick,
  };
}

/// Aktualisiert Connect auf Klick: lädt das Paket der neuesten Version, prüft
/// Größe, SHA-256 und (am Mac) Apple-Signatur samt Notarisierung und öffnet
/// erst dann den Installer beim angemeldeten Benutzer.
///
/// Installiert wird nie still: Bestätigen, Kennwort/Touch ID und Abschluss
/// macht der Mensch im Installer; dessen postinstall startet Connect neu.
/// Woher geladen wird, bestimmt allein der Feed (der nur unser Release
/// zulässt) – über die API lässt sich weder Adresse noch Version vorgeben.
class ConnectUpdater {
  ConnectUpdater({
    required UpdateFeed feed,
    required Downloader download,
    required ProcessRunner run,
    required EventBus events,
    required this.cacheDir,
    required this.platformKey,
    this.current = agentVersion,
    String? operatingSystem,
    DateTime Function()? clock,
  }) : _feed = feed,
       _download = download,
       _run = run,
       _events = events,
       _os = operatingSystem ?? Platform.operatingSystem,
       _clock = clock ?? DateTime.now;

  final UpdateFeed _feed;
  final Downloader _download;
  final ProcessRunner _run;
  final EventBus _events;
  final String _os;
  final DateTime Function() _clock;

  /// Ordner für geladene Pakete.
  final Directory cacheDir;

  /// Plattformschlüssel wie in `latest.json` (z. B. `darwin-arm64`).
  final String platformKey;

  /// Laufende Version.
  final String current;

  Future<void>? _running;

  /// Ob eine Aktualisierung läuft.
  bool get busy => _running != null;

  /// Die laufende Aktualisierung (für Tests), `null` ohne.
  Future<void>? get running => _running;

  /// Ein-Klick gibt es nur am Mac (signiertes, notarisiertes Paket).
  bool get oneClick => _os == 'macos';

  Future<UpdateInfo> info() async {
    final entry = await _feed.latest(platformKey);
    return UpdateInfo(
      current: current,
      latest: entry?.version,
      available: entry != null && isNewer(entry.version, current),
      platform: platformKey,
      size: entry?.size,
      oneClick: oneClick,
    );
  }

  /// Startet die Aktualisierung und kehrt sofort zurück; der Rest meldet sich
  /// über `update.progress`, `update.failed` und `agent.restarting`.
  Future<void> start() async {
    if (!oneClick) {
      throw const UpdateFailure(
        errorUpdateUnsupported,
        'Auf diesem System geht die Aktualisierung nur über den Download.',
      );
    }
    if (busy) {
      throw const UpdateFailure(
        errorUpdateBusy,
        'Die Aktualisierung läuft bereits.',
      );
    }
    final entry = await _feed.latest(platformKey);
    if (entry == null || !isNewer(entry.version, current)) {
      throw const UpdateFailure(
        errorUpdateNotAvailable,
        'Es gibt keine neuere Version.',
      );
    }
    if (busy) {
      throw const UpdateFailure(
        errorUpdateBusy,
        'Die Aktualisierung läuft bereits.',
      );
    }
    _running = _perform(entry).whenComplete(() => _running = null);
  }

  Future<void> _perform(FeedEntry entry) async {
    final name = p.basename(entry.url.path);
    final target = File(p.join(cacheDir.path, '${entry.version}-$name'));
    var openAttempted = false;
    try {
      await cacheDir.create(recursive: true);
      if (target.existsSync()) await target.delete();

      _progress(entry, 'download', 0);
      var lastPercent = 0;
      try {
        await _download(entry.url, target, (received, total) {
          final size = total ?? entry.size;
          final percent = size <= 0
              ? 0
              : (received * 100 ~/ size).clamp(0, 100);
          if (percent >= lastPercent + 10 || percent == 100) {
            lastPercent = percent;
            _progress(entry, 'download', percent);
          }
        });
      } on Object {
        throw const UpdateFailure(
          errorUpdateDownloadFailed,
          'Die neue Version konnte nicht geladen werden.',
        );
      }

      _progress(entry, 'check', 100);
      final length = target.existsSync() ? await target.length() : -1;
      final digest = length == entry.size
          ? (await sha256.bind(target.openRead()).first).toString()
          : null;
      if (digest != entry.sha256) {
        throw const UpdateFailure(
          errorUpdateChecksumMismatch,
          'Die neue Version ist nicht vollständig angekommen.',
        );
      }
      if (!await verifyMacPackage(target, run: _run)) {
        throw const UpdateFailure(
          errorUpdateSignatureInvalid,
          'Die neue Version konnte nicht geprüft werden.',
        );
      }
      if (!isNewer(entry.version, current)) {
        throw const UpdateFailure(
          errorUpdateNotNewer,
          'Die geladene Version ist nicht neuer.',
        );
      }

      _progress(entry, 'ready', 100);
      _events.publish(eventAgentRestarting, <String, Object?>{
        'reason': 'update',
        'version': entry.version,
      });
      openAttempted = true;
      final opened = await _run('open', <String>[target.path]);
      if (opened.exitCode != 0) {
        throw const UpdateFailure(
          errorUpdateOpenFailed,
          'Der Installer konnte nicht geöffnet werden.',
        );
      }
    } on Object catch (error) {
      final failure = error is UpdateFailure
          ? error
          : const UpdateFailure(
              errorUpdateDownloadFailed,
              'Die neue Version konnte nicht geladen werden.',
            );
      // Ein nicht geöffnetes, aber geprüftes Paket bleibt bis zum Aufräumen
      // liegen; alles andere ist sofort weg.
      if (!openAttempted && target.existsSync()) {
        try {
          await target.delete();
        } on Object {
          // Aufräumen beim nächsten Start.
        }
      }
      _events.publish(eventUpdateFailed, <String, Object?>{
        'version': entry.version,
        'code': failure.code,
        'message': failure.message,
      });
    }
  }

  void _progress(FeedEntry entry, String phase, int percent) =>
      _events.publish(eventUpdateProgress, <String, Object?>{
        'version': entry.version,
        'phase': phase,
        'percent': percent,
      });

  /// Entfernt geladene Pakete, die älter als 24 Stunden sind. Wirft nie.
  Future<void> cleanup() async {
    try {
      if (!cacheDir.existsSync()) return;
      final limit = _clock().subtract(_keepDownloads);
      await for (final entity in cacheDir.list()) {
        if (entity is! File) continue;
        if (entity.lastModifiedSync().isBefore(limit)) await entity.delete();
      }
    } on Object {
      // Nächster Start.
    }
  }
}

/// Echter Download über HTTPS; folgt Weiterleitungen nur zu
/// [updateDownloadHosts] und höchstens fünfmal.
Downloader httpDownloader({
  Duration timeout = const Duration(minutes: 5),
}) => (url, target, onProgress) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    var uri = url;
    for (var hop = 0; ; hop++) {
      if (uri.scheme != 'https' || !updateDownloadHosts.contains(uri.host)) {
        throw HttpException('Adresse nicht erlaubt', uri: uri);
      }
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.isRedirect) {
        await response.drain<void>();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || hop >= 5) {
          throw HttpException('Weiterleitung ungültig', uri: uri);
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final total = response.contentLength >= 0 ? response.contentLength : null;
      final sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(timeout)) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      return;
    }
  } finally {
    client.close(force: true);
  }
};
