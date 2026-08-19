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
  ///
  /// Die Klammer aus `_queue` (dieser Prozess) und der Sperrdatei
  /// (`config.lock`, alle Prozesse) macht Laden → Ändern → Umbenennen
  /// unteilbar: `kasseneck-connect pair` läuft neben `run`, und ohne die
  /// Dateisperre überschriebe der langsamere Prozess die Änderung des
  /// schnelleren.
  Future<AgentConfig> mutate(AgentConfig Function(AgentConfig current) change) {
    final result = _queue.then((_) async {
      final lock = await _acquireLock();
      try {
        final current = await load();
        final updated = change(current);
        await save(updated);
        return updated;
      } finally {
        await _releaseLock(lock);
      }
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

    final temp = paths.configTempFile();
    final json = const JsonEncoder.withIndent('  ').convert(config.toJson());
    await temp.writeAsString('$json\n', flush: true);
    _restrict(temp.path, '600');
    await temp.rename(file.path);
  }

  /// Holt die prozessübergreifende Sperre (blockiert, bis sie frei ist).
  ///
  /// `FileLock.blockingExclusive` gibt es auf macOS, Linux und Windows. Lässt
  /// sich die Sperrdatei nicht öffnen (nur-lesbares Verzeichnis), läuft der
  /// Schreibvorgang ungesperrt weiter — lieber eine seltene Kollision als ein
  /// Agent, der gar nichts mehr speichern kann.
  Future<RandomAccessFile?> _acquireLock() async {
    final directory = paths.directory;
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
      _restrict(directory.path, '700');
    }
    try {
      final handle = await paths.configLockFile.open(mode: FileMode.write);
      await handle.lock(FileLock.blockingExclusive);
      return handle;
    } on FileSystemException {
      return null;
    }
  }

  /// Gibt die Sperre frei; Fehler dabei dürfen den Aufrufer nicht treffen.
  Future<void> _releaseLock(RandomAccessFile? handle) async {
    if (handle == null) return;
    try {
      await handle.unlock();
    } on FileSystemException {
      // Schon freigegeben — nichts zu tun.
    }
    try {
      await handle.close();
    } on FileSystemException {
      // Handle war bereits zu.
    }
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
