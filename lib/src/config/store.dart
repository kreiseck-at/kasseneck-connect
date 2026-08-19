import 'dart:convert';
import 'dart:io';

import 'model.dart';
import 'paths.dart';

/// Liest und schreibt die `config.json` im Datenverzeichnis des Agenten.
///
/// Geschrieben wird immer atomar: erst in `config.json.tmp`, dann `rename`.
/// So bleibt bei Stromausfall entweder die alte oder die neue Datei vollständig
/// stehen — nie ein halber Torso.
class ConfigStore {
  ConfigStore(this.paths);

  /// Bequemer Einstieg über ein Verzeichnis.
  factory ConfigStore.forDirectory(Directory directory) =>
      ConfigStore(ConfigPaths(directory));

  final ConfigPaths paths;

  /// Serialisiert die Änderungen dieses Prozesses.
  Future<void> _queue = Future<void>.value();

  File get file => paths.configFile;

  /// Ändert die Konfiguration: frisch laden, [change] anwenden, atomar
  /// schreiben. Aufrufe laufen nacheinander, damit zwei Änderungen sich nicht
  /// gegenseitig überschreiben.
  ///
  /// Das ist der vorgesehene Weg für alle Schreibzugriffe (Kopplung, Drucker,
  /// Terminal) — nie `load()`/`save()` von Hand kombinieren.
  Future<AgentConfig> mutate(AgentConfig Function(AgentConfig current) change) {
    final result = _queue.then((_) async {
      final current = await load();
      final updated = change(current);
      await save(updated);
      return updated;
    });
    _queue = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  /// Lädt die Konfiguration. Fehlt oder bricht die Datei, liefert `load()`
  /// die Standardkonfiguration — der Agent startet dann mit leerem Zustand.
  Future<AgentConfig> load() async {
    final target = file;
    if (!target.existsSync()) return AgentConfig();
    try {
      final raw = await target.readAsString();
      if (raw.trim().isEmpty) return AgentConfig();
      final decoded = jsonDecode(raw) as Object?;
      final map = readMap(decoded);
      if (map == null) return AgentConfig();
      return AgentConfig.fromJson(map);
    } on FormatException {
      return AgentConfig();
    } on FileSystemException {
      return AgentConfig();
    }
  }

  /// Schreibt die Konfiguration atomar und setzt die Rechte auf 600 (POSIX).
  Future<void> save(AgentConfig config) async {
    final directory = paths.directory;
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
      _restrict(directory.path, '700');
    }

    final temp = paths.configTempFile;
    final json = const JsonEncoder.withIndent('  ').convert(config.toJson());
    await temp.writeAsString('$json\n', flush: true);
    _restrict(temp.path, '600');
    await temp.rename(file.path);
  }

  /// Setzt Dateirechte, soweit das Betriebssystem sie kennt.
  static void _restrict(String path, String mode) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', <String>[mode, path]);
    } on ProcessException {
      // Ohne `chmod` (exotische Umgebung) bleibt es bei den Standardrechten.
    }
  }
}
