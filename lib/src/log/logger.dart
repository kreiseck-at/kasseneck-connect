import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'aufbewahrung.dart';

/// Schweregrad eines Logeintrags.
enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warn('WARN'),
  error('ERROR');

  const LogLevel(this.label);

  final String label;
}

/// Ein einzelner Logeintrag (auch für `GET /v1/status` verwendet).
class LogEntry {
  const LogEntry(this.time, this.level, this.message);

  final DateTime time;
  final LogLevel level;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'time': time.toIso8601String(),
    'level': level.label.toLowerCase(),
    'message': message,
  };

  @override
  String toString() => '${time.toIso8601String()}  ${level.label}  $message';
}

/// Rotierendes Textlog des Agenten.
///
/// Geschrieben wird nach `connect.log`; beim ersten Eintrag eines neuen Tages
/// wandert die bisherige Datei nach `connect-JJJJ-MM-TT.log`, und es bleiben
/// die Dateien der letzten [maxFiles] Tage stehen (Standard 7). Erreicht die
/// Datei [maxFileBytes], wandert sie schon vorher nach
/// `connect-JJJJ-MM-TT-n.log`; alle Dateien zusammen bleiben unter
/// [maxTotalBytes], die älteste geht zuerst (siehe `aufbewahrung.dart`).
///
/// **Keine Beleginhalte, keine Kartendaten ins Log** — nur IDs, Fehlercodes und
/// grobe Beträge.
class AgentLog {
  AgentLog(
    this.directory, {
    DateTime Function()? clock,
    this.maxFiles = 7,
    this.errorBufferSize = 50,
    this.minimumLevel = LogLevel.info,
    this.echoToStdout = false,
    this.maxFileBytes = logDateiGrenze,
    this.maxTotalBytes = logGesamtGrenze,
  }) : _clock = clock ?? DateTime.now {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final current = file;
    if (current.existsSync()) {
      _currentDay = _dayOf(current.lastModifiedSync());
    }
  }

  /// Verzeichnis der Logdateien.
  final Directory directory;

  /// Maximale Anzahl vorgehaltener Logdateien (aktuelle inklusive).
  final int maxFiles;

  /// Größe des Ringpuffers der letzten Fehler.
  final int errorBufferSize;

  /// Einträge unterhalb dieses Schweregrads werden verworfen.
  final LogLevel minimumLevel;

  /// Zusätzlich auf die Konsole schreiben (Vordergrundbetrieb, `doctor`).
  final bool echoToStdout;

  /// Größte Logdatei, bevor sie in einen Teil wandert.
  final int maxFileBytes;

  /// Alle Logdateien zusammen.
  final int maxTotalBytes;

  final DateTime Function() _clock;
  final List<LogEntry> _recentErrors = <LogEntry>[];
  String? _currentDay;

  /// Aktuelle Logdatei.
  File get file => fileIn(directory);

  /// Die aktuelle Logdatei eines Verzeichnisses, ohne ein [AgentLog] zu bauen.
  ///
  /// Die Diagnose (`doctor`) braucht nur den Pfad und darf dabei nichts
  /// anlegen — der Konstruktor legt das Verzeichnis an.
  static File fileIn(Directory directory) =>
      File(p.join(directory.path, 'connect.log'));

  /// Die letzten Fehler (ältester zuerst), höchstens [errorBufferSize] Stück.
  List<LogEntry> get recentErrors => List<LogEntry>.unmodifiable(_recentErrors);

  void debug(String message) => log(LogLevel.debug, message);

  void info(String message) => log(LogLevel.info, message);

  void warn(String message) => log(LogLevel.warn, message);

  void error(String message, [Object? cause]) =>
      log(LogLevel.error, cause == null ? message : '$message: $cause');

  /// Schreibt einen Eintrag und rotiert bei Tageswechsel.
  void log(LogLevel level, String message) {
    if (level.index < minimumLevel.index) return;
    final now = _clock();
    final entry = LogEntry(now, level, _flatten(message));

    if (level == LogLevel.error) {
      _recentErrors.add(entry);
      while (_recentErrors.length > errorBufferSize) {
        _recentErrors.removeAt(0);
      }
    }

    _rotateIfNeeded(now);
    final line =
        '${_stamp(now)}  ${level.label.padRight(5)}  ${entry.message}\n';
    _rotateIfTooLarge(utf8.encode(line).length);
    try {
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } on FileSystemException {
      // Ein nicht schreibbares Log darf den Agenten nicht anhalten.
    }
    if (echoToStdout) stdout.write(line);
  }

  /// Verschiebt die aktuelle Datei, sobald ein neuer Tag beginnt, und räumt
  /// alte Dateien ab.
  void _rotateIfNeeded(DateTime now) {
    final today = _dayOf(now);
    final previous = _currentDay;
    _currentDay = today;
    if (previous == null || previous == today) return;

    final current = file;
    if (current.existsSync()) {
      final archive = File(p.join(directory.path, 'connect-$previous.log'));
      try {
        if (archive.existsSync()) archive.deleteSync();
        current.renameSync(archive.path);
      } on FileSystemException {
        return;
      }
    }
    _prune();
  }

  /// Verschiebt die aktuelle Datei in einen Teil des Tages, wenn [zusatz]
  /// weitere Bytes sie über [maxFileBytes] höben.
  void _rotateIfTooLarge(int zusatz) {
    final current = file;
    final int bytes;
    try {
      bytes = current.lengthSync();
    } on FileSystemException {
      // Noch keine Datei – nichts zu verschieben.
      return;
    }
    if (bytes == 0 || bytes + zusatz <= maxFileBytes) return;
    final day = _currentDay ?? _dayOf(_clock());
    final ziel = teilReservieren(directory, day, _archiveNames());
    if (ziel == null) return;
    try {
      current.renameSync(ziel.path);
    } on FileSystemException {
      // Gesperrt oder Platte voll: weiter in dieselbe Datei schreiben – ein
      // zu großes Log ist besser als ein Agent, der wegen des Logs stockt.
      try {
        ziel.deleteSync();
      } on FileSystemException {
        // Der leere Platzhalter bleibt; der nächste Teil nimmt die nächste
        // Nummer.
      }
      return;
    }
    _prune();
  }

  /// Reserviert den nächsten freien Teil des Tages [tag] in [verzeichnis]:
  /// die Datei wird exklusiv angelegt, bevor das Log hineinwandert. Zwei
  /// Prozesse (Agent und Kommandozeile), die zugleich rotieren, bekämen sonst
  /// denselben Namen, und der zweite überschriebe den Teil des ersten.
  /// `null`, wenn sich keiner anlegen lässt.
  static File? teilReservieren(
    Directory verzeichnis,
    String tag,
    Iterable<String> vorhanden,
  ) {
    final belegt = vorhanden.toSet();
    for (var versuch = 0; versuch < 50; versuch++) {
      final name = naechsterTeilName(tag, belegt);
      final datei = File(p.join(verzeichnis.path, name));
      try {
        datei.createSync(exclusive: true);
        return datei;
      } on FileSystemException {
        // Schon da (anderer Prozess war schneller) oder nicht anlegbar.
        belegt.add(name);
      }
    }
    return null;
  }

  List<String> _archiveNames() => directory
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where((name) => LogArchiv.ausName(name, 0) != null)
      .toList();

  /// Räumt Archive ab: nur die letzten [maxFiles] Tage (mit der aktuellen
  /// Datei) und alles zusammen höchstens [maxTotalBytes].
  void _prune() {
    final archive = <LogArchiv>[];
    for (final datei in directory.listSync().whereType<File>()) {
      final int bytes;
      try {
        bytes = datei.lengthSync();
      } on FileSystemException {
        // Eben verschwunden (zweiter Prozess räumt auch): nicht mitzählen.
        continue;
      }
      final archiv = LogArchiv.ausName(p.basename(datei.path), bytes);
      if (archiv != null) archive.add(archiv);
    }
    int aktuell;
    try {
      aktuell = file.existsSync() ? file.lengthSync() : 0;
    } on FileSystemException {
      aktuell = 0;
    }
    final weg = zuLoeschendeArchive(
      archive,
      // Die aktuelle Datei zählt als einer der Tage.
      maxTage: maxFiles - 1,
      aktuellerTag: _currentDay ?? _dayOf(_clock()),
      aktuelleBytes: aktuell,
      maxGesamtBytes: maxTotalBytes,
    );
    for (final name in weg) {
      try {
        File(p.join(directory.path, name)).deleteSync();
      } on FileSystemException {
        // Weiterräumen, auch wenn eine Datei gesperrt ist; der nächste
        // Wechsel versucht es wieder.
      }
    }
  }

  static String _dayOf(DateTime time) {
    final t = time.toLocal();
    final month = t.month.toString().padLeft(2, '0');
    final day = t.day.toString().padLeft(2, '0');
    return '${t.year}-$month-$day';
  }

  static String _stamp(DateTime time) {
    final t = time.toLocal();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${_dayOf(t)} $hh:$mm:$ss.$ms';
  }

  /// Ein Eintrag ist immer eine Zeile — Umbrüche würden das Log zerreißen.
  static String _flatten(String message) =>
      message.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
}
