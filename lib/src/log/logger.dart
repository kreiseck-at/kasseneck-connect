import 'dart:io';

import 'package:path/path.dart' as p;

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
/// höchstens [maxFiles] Dateien stehen (Standard 7 Tage).
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

  final DateTime Function() _clock;
  final List<LogEntry> _recentErrors = <LogEntry>[];
  String? _currentDay;

  /// Aktuelle Logdatei.
  File get file => File(p.join(directory.path, 'connect.log'));

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

  /// Behält die neuesten Archive, sodass mit der aktuellen Datei höchstens
  /// [maxFiles] Dateien liegen bleiben.
  void _prune() {
    final archives =
        directory.listSync().whereType<File>().where((f) {
            final name = p.basename(f.path);
            return name.startsWith('connect-') && name.endsWith('.log');
          }).toList()
          ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));

    final keep = maxFiles - 1;
    for (var i = keep; i < archives.length; i++) {
      try {
        archives[i].deleteSync();
      } on FileSystemException {
        // Weiterräumen, auch wenn eine Datei gesperrt ist.
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
