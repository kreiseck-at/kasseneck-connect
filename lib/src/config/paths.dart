import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

final Random _random = Random();

/// Umgebungsvariable, mit der das Datenverzeichnis überschrieben wird
/// (für Tests und portable Installationen).
const String configHomeEnvVar = 'KASSENECK_CONNECT_HOME';

/// Verzeichnisse des Agenten je Betriebssystem.
///
/// - macOS:   `~/Library/Application Support/KasseneckConnect`
/// - Windows: `%ProgramData%\KasseneckConnect`
/// - sonst:   `$XDG_CONFIG_HOME/kasseneck-connect` bzw. `~/.config/kasseneck-connect`
class ConfigPaths {
  const ConfigPaths(this.directory);

  /// Basisverzeichnis für Konfiguration und Log.
  final Directory directory;

  /// Ermittelt die Pfade für das laufende System.
  ///
  /// [environment] und [operatingSystem] sind injizierbar, damit die Ableitung
  /// ohne echtes Betriebssystem testbar bleibt.
  factory ConfigPaths.forPlatform({
    Map<String, String>? environment,
    String? operatingSystem,
  }) {
    final env = environment ?? Platform.environment;
    final os = operatingSystem ?? Platform.operatingSystem;

    final override = env[configHomeEnvVar];
    if (override != null && override.trim().isNotEmpty) {
      return ConfigPaths(Directory(override.trim()));
    }

    switch (os) {
      case 'macos':
        final home = env['HOME'] ?? '';
        return ConfigPaths(
          Directory(
            p.join(home, 'Library', 'Application Support', 'KasseneckConnect'),
          ),
        );
      case 'windows':
        final programData =
            env['ProgramData'] ?? env['PROGRAMDATA'] ?? r'C:\ProgramData';
        return ConfigPaths(Directory(p.join(programData, 'KasseneckConnect')));
      default:
        final xdg = env['XDG_CONFIG_HOME'];
        final base = (xdg != null && xdg.trim().isNotEmpty)
            ? xdg.trim()
            : p.join(env['HOME'] ?? '', '.config');
        return ConfigPaths(Directory(p.join(base, 'kasseneck-connect')));
    }
  }

  /// `config.json` im Basisverzeichnis.
  File get configFile => File(p.join(directory.path, 'config.json'));

  /// Temporärdatei des atomaren Schreibvorgangs.
  ///
  /// Der Name enthält Prozess-ID und Zufall: `run` und `pair` schreiben
  /// gleichzeitig, und ein fester Name (`config.json.tmp`) würde bedeuten, dass
  /// ein Prozess die halbfertige Datei des anderen umbenennt.
  File configTempFile([Random? random]) {
    final suffix = (random ?? _random).nextInt(1 << 32).toRadixString(36);
    return File(p.join(directory.path, 'config.json.$pid.$suffix.tmp'));
  }

  /// Sperrdatei, über die sich mehrere Prozesse abstimmen.
  File get configLockFile => File(p.join(directory.path, 'config.lock'));

  /// Verzeichnis der rotierenden Logdateien.
  Directory get logDirectory => Directory(p.join(directory.path, 'logs'));

  @override
  String toString() => 'ConfigPaths(${directory.path})';
}
