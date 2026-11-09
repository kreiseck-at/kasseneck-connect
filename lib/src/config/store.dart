import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../log/logger.dart';
import 'model.dart';
import 'paths.dart';

/// Liest und schreibt die `config.json` im Datenverzeichnis des Agenten.
///
/// Geschrieben wird immer atomar: erst in eine Temp-Datei, dann `rename`.
/// So bleibt bei Stromausfall entweder die alte oder die neue Datei vollständig
/// stehen — nie ein halber Torso.
///
/// **Eine unbrauchbare Datei geht nie verloren.** In der `config.json` stehen
/// Kopplungen und Drucker; fiele `load()` bei einer kaputten Datei still auf
/// die Standardkonfiguration zurück, überschriebe das nächste `mutate` beides
/// endgültig. Deshalb:
///
/// - Vor jedem Ersetzen wandert die bisherige gute Fassung nach
///   `config.json.bak` (atomar, Rechte 600).
/// - Ist die `config.json` unbrauchbar (kein JSON, leer, kein Objekt, nicht
///   lesbar), legt `load()` einmalig eine Kopie als
///   `config.json.defekt-<UTC-Zeitstempel>` ab (Rechte 600), meldet das als
///   Fehler im Log und nimmt die Sicherung `config.json.bak`; erst wenn auch
///   die fehlt oder unbrauchbar ist, die Standardkonfiguration.
/// - `load()` schreibt die `config.json` selbst nie: es läuft auch außerhalb
///   der Sperre, neben einem `mutate` im anderen Prozess (`pair` neben
///   `run`). Ersetzt wird die kaputte Datei erst vom nächsten `mutate`, unter
///   der Sperre – und erst, wenn sie aufbewahrt ist.
/// - Fehlen `config.json` und Sicherung, ist das der Erststart: still.
class ConfigStore {
  ConfigStore(this.paths, {AgentLog? log, DateTime Function()? clock})
    : _log = log,
      _clock = clock ?? DateTime.now;

  /// Bequemer Einstieg über ein Verzeichnis.
  factory ConfigStore.forDirectory(
    Directory directory, {
    AgentLog? log,
    DateTime Function()? clock,
  }) => ConfigStore(ConfigPaths(directory), log: log, clock: clock);

  final ConfigPaths paths;

  final AgentLog? _log;

  /// Uhr für den Zeitstempel der aufbewahrten Fassungen (Tests).
  final DateTime Function() _clock;

  /// Serialisiert die Änderungen dieses Prozesses.
  Future<void> _queue = Future<void>.value();

  /// Aufbewahrung je Inhalt (SHA-256): `load()` läuft bei jeder Anfrage, die
  /// Kopie entsteht trotzdem nur einmal, auch bei gleichzeitigen Aufrufen.
  final Map<String, Future<void>> _aufbewahrt = <String, Future<void>>{};

  /// Was schon gemeldet ist — sonst wüchse das Log mit jeder Anfrage.
  final Set<String> _gemeldet = <String>{};

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

  /// Lädt die Konfiguration.
  ///
  /// Fehlt die Datei (Erststart), kommt still die Standardkonfiguration. Ist
  /// sie unbrauchbar, bleibt sie als `config.json.defekt-…` erhalten und die
  /// Sicherung `config.json.bak` springt ein (siehe [ConfigStore]).
  Future<AgentConfig> load() async {
    final haupt = await _lies(file);
    if (haupt.config != null) return haupt.config!;

    if (haupt.fehlt) {
      final sicherung = await _lies(paths.configBackupFile);
      if (sicherung.config == null) return AgentConfig();
      // Gelöscht wird die config.json von Connect nie; wer sie von Hand
      // entfernt, will meist zurücksetzen – und soll sehen, warum die
      // Kopplungen trotzdem bleiben.
      _melde(
        'fehlt',
        'config.json fehlt – Connect nimmt die Sicherung config.json.bak.',
        fehler: false,
      );
      return sicherung.config!;
    }

    try {
      await _bewahre(haupt);
    } on FileSystemException catch (e) {
      // Lesen soll weiter gehen; ersetzt wird die Datei ohnehin erst von
      // save(), und das bricht ab, solange sie nicht aufbewahrt ist.
      _melde(
        'ablage:${haupt.kennung}',
        'Die unbrauchbare config.json ließ sich nicht aufbewahren: '
            '${e.message}',
      );
    }
    final sicherung = await _lies(paths.configBackupFile);
    if (sicherung.config != null) {
      _melde(
        'sicherung:${haupt.kennung}',
        'config.json ist unbrauchbar (${haupt.grund}) – Connect nimmt die '
            'Sicherung config.json.bak.',
      );
      return sicherung.config!;
    }
    _melde(
      'standard:${haupt.kennung}',
      'config.json ist unbrauchbar (${haupt.grund}) und es gibt keine '
          'brauchbare Sicherung – Connect startet ohne Kopplungen und Drucker.',
    );
    return AgentConfig();
  }

  /// Schreibt die Konfiguration atomar und setzt die Rechte auf 600 (POSIX).
  ///
  /// Vorher wird die bisherige Datei gesichert: eine gute als
  /// `config.json.bak`, eine unbrauchbare als `config.json.defekt-…`. Lässt
  /// sich eine unbrauchbare Datei nicht aufbewahren, bricht das Speichern ab
  /// – lieber eine Änderung verlieren als die alte Datei.
  Future<void> save(AgentConfig config) async {
    await _verzeichnisAnlegen();

    final temp = paths.configTempFile();
    final json = const JsonEncoder.withIndent('  ').convert(config.toJson());
    try {
      await temp.writeAsString('$json\n', flush: true);
      _restrict(temp.path, '600');
      await _sichereVorige();
      await temp.rename(file.path);
    } on Object {
      // Bleibt die Datei liegen (volle Platte, Rechte weg), sammeln sich sonst
      // mit jedem Versuch neue `.tmp`-Reste im Datenverzeichnis an.
      _wegraeumen(temp);
      rethrow;
    }
  }

  /// Sichert die Datei, die [save] gleich ersetzt.
  Future<void> _sichereVorige() async {
    final vorige = await _lies(file);
    if (vorige.fehlt) return;
    if (vorige.config != null) {
      // Die gute Fassung als Sicherung. Scheitert das, bleibt die ältere
      // Sicherung stehen – die config.json selbst ist ja gut.
      try {
        await _schreibeAtomar(paths.configBackupFile, vorige.bytes!);
      } on FileSystemException catch (e) {
        _log?.warn('config.json.bak ließ sich nicht schreiben: ${e.message}');
      }
      return;
    }
    if (vorige.bytes != null) {
      await _bewahre(vorige);
      return;
    }
    if (!vorige.istDatei) {
      // Ein Ordner o. Ä. unter dem Namen: nicht anfassen, das Umbenennen
      // scheitert dann und meldet es.
      return;
    }
    // Nicht lesbar, also auch nicht kopierbar: die Datei selbst beiseite
    // stellen. Unter der Sperre (mutate) ist das ungefährlich; ein Leser
    // ohne Sperre fällt für den Augenblick auf die Sicherung zurück.
    final ziel = _freierDefektName();
    await file.rename(ziel.path);
    _restrict(ziel.path, '600');
    _log?.error(
      'config.json war nicht lesbar (${vorige.grund}) – aufbewahrt als '
      '${ziel.uri.pathSegments.last}.',
    );
  }

  /// Legt einmalig eine Kopie der unbrauchbaren Fassung [kaputt] ab.
  ///
  /// Gleicher Inhalt wird nicht zweimal abgelegt: in diesem Prozess merkt
  /// sich das ein Gedächtnis je Prüfsumme, über Prozesse hinweg genügt eine
  /// schon liegende `config.json.defekt-…` mit genau diesem Inhalt. Lesen
  /// `run` und `pair` die kaputte Datei im selben Augenblick zum ersten Mal,
  /// kann es zwei gleiche Ablagen geben – lieber das als keine. Ohne Inhalt
  /// (nicht lesbar) gibt es nichts zu kopieren — das übernimmt [save].
  Future<void> _bewahre(_Gelesen kaputt) {
    final bytes = kaputt.bytes;
    if (bytes == null) return Future<void>.value();
    final laufend = _aufbewahrt[kaputt.kennung];
    if (laufend != null) return laufend;
    final arbeit = () async {
      if (_schonAufbewahrt(bytes)) return;
      final ziel = _freierDefektName();
      await _schreibeAtomar(ziel, bytes);
      _log?.error(
        'config.json ist unbrauchbar (${kaputt.grund}) – aufbewahrt als '
        '${ziel.uri.pathSegments.last}.',
      );
    }();
    _aufbewahrt[kaputt.kennung] = arbeit;
    // Scheitert die Ablage, beim nächsten Mal neu versuchen.
    arbeit.catchError((Object _) {
      _aufbewahrt.remove(kaputt.kennung);
    });
    return arbeit;
  }

  bool _schonAufbewahrt(List<int> bytes) {
    final dir = paths.directory;
    if (!dir.existsSync()) return false;
    for (final eintrag in dir.listSync(followLinks: false)) {
      if (eintrag is! File) continue;
      final name = eintrag.uri.pathSegments.last;
      if (!name.startsWith(ConfigPaths.configDefektPrefix)) continue;
      try {
        if (eintrag.lengthSync() != bytes.length) continue;
        if (_gleich(eintrag.readAsBytesSync(), bytes)) return true;
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  File _freierDefektName() {
    final jetzt = _clock();
    for (var nummer = 1; ; nummer++) {
      final kandidat = paths.configDefektFile(jetzt, nummer);
      if (FileSystemEntity.typeSync(kandidat.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return kandidat;
      }
    }
  }

  /// Schreibt [bytes] atomar nach [ziel] (Temp-Datei, Rechte 600, rename).
  Future<void> _schreibeAtomar(File ziel, List<int> bytes) async {
    final temp = paths.configTempFile();
    try {
      await temp.writeAsBytes(bytes, flush: true);
      _restrict(temp.path, '600');
      await temp.rename(ziel.path);
    } on Object {
      _wegraeumen(temp);
      rethrow;
    }
  }

  /// Liest [datei] und ordnet sie ein: fehlt, gut oder unbrauchbar.
  Future<_Gelesen> _lies(File datei) async {
    final typ = FileSystemEntity.typeSync(datei.path);
    if (typ == FileSystemEntityType.notFound) return const _Gelesen.fehlt();
    if (typ != FileSystemEntityType.file) {
      return _Gelesen.kaputt(
        grund: 'kein Datei-Eintrag ($typ)',
        istDatei: false,
      );
    }
    final List<int> bytes;
    try {
      bytes = await datei.readAsBytes();
    } on FileSystemException catch (e) {
      // Zwischen Prüfen und Lesen verschwunden: wie fehlend behandeln.
      if (!datei.existsSync()) return const _Gelesen.fehlt();
      return _Gelesen.kaputt(
        grund: 'nicht lesbar: ${e.osError?.message ?? e.message}',
      );
    }
    final kennung = sha256.convert(bytes).toString();
    try {
      final text = utf8.decode(bytes);
      if (text.trim().isEmpty) {
        return _Gelesen.kaputt(grund: 'leer', bytes: bytes, kennung: kennung);
      }
      final map = readMap(jsonDecode(text));
      if (map == null) {
        return _Gelesen.kaputt(
          grund: 'kein JSON-Objekt',
          bytes: bytes,
          kennung: kennung,
        );
      }
      return _Gelesen.gut(AgentConfig.fromJson(map), bytes);
    } on FormatException {
      return _Gelesen.kaputt(
        grund: 'kein gültiges JSON',
        bytes: bytes,
        kennung: kennung,
      );
    }
  }

  void _melde(String schluessel, String text, {bool fehler = true}) {
    if (!_gemeldet.add(schluessel)) return;
    if (fehler) {
      _log?.error(text);
    } else {
      _log?.warn(text);
    }
  }

  Future<void> _verzeichnisAnlegen() async {
    final directory = paths.directory;
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
      _restrict(directory.path, '700');
    }
  }

  static void _wegraeumen(File temp) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Auch das Aufräumen darf den eigentlichen Fehler nicht verdecken.
    }
  }

  static bool _gleich(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Holt die prozessübergreifende Sperre (blockiert, bis sie frei ist).
  ///
  /// `FileLock.blockingExclusive` gibt es auf macOS, Linux und Windows. Lässt
  /// sich die Sperrdatei nicht öffnen (nur-lesbares Verzeichnis), läuft der
  /// Schreibvorgang ungesperrt weiter — lieber eine seltene Kollision als ein
  /// Agent, der gar nichts mehr speichern kann.
  Future<RandomAccessFile?> _acquireLock() async {
    await _verzeichnisAnlegen();
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

/// Eine gelesene Konfigurationsdatei.
class _Gelesen {
  const _Gelesen.fehlt()
    : fehlt = true,
      config = null,
      bytes = null,
      grund = null,
      kennung = '',
      istDatei = false;

  const _Gelesen.gut(AgentConfig this.config, List<int> this.bytes)
    : fehlt = false,
      grund = null,
      kennung = '',
      istDatei = true;

  const _Gelesen.kaputt({
    required String this.grund,
    this.bytes,
    this.kennung = 'unlesbar',
    this.istDatei = true,
  }) : fehlt = false,
       config = null;

  /// Die Datei gibt es nicht.
  final bool fehlt;

  /// Die Konfiguration, wenn die Datei brauchbar ist.
  final AgentConfig? config;

  /// Der rohe Inhalt (gut oder unbrauchbar); `null`, wenn nicht lesbar.
  final List<int>? bytes;

  /// Warum unbrauchbar — für das Log.
  final String? grund;

  /// SHA-256 des Inhalts einer unbrauchbaren Datei (Gedächtnis der Ablage).
  final String kennung;

  /// Ein normaler Datei-Eintrag (nicht ein Ordner unter dem Namen).
  final bool istDatei;
}
