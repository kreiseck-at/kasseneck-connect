import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('connect-log-'));
  tearDown(() => temp.deleteSync(recursive: true));

  List<String> archiveNames(Directory dir) =>
      dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((name) => name.startsWith('connect-'))
          .toList()
        ..sort();

  test('schreibt Zeit, Level und Nachricht nach connect.log', () {
    final log = AgentLog(temp, clock: () => DateTime(2026, 8, 19, 14, 5, 6, 7));
    log.info('Agent gestartet');
    log.error('Drucker nicht erreichbar', 'timeout');

    final lines = log.file.readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines[0], startsWith('2026-08-19 14:05:06.007  INFO '));
    expect(lines[0], endsWith('Agent gestartet'));
    expect(lines[1], contains('ERROR'));
    expect(lines[1], contains('Drucker nicht erreichbar: timeout'));
  });

  test('Einträge unterhalb des Mindestlevels werden verworfen', () {
    final log = AgentLog(temp, clock: () => DateTime(2026, 8, 19));
    log.debug('nicht interessant');
    expect(log.file.existsSync(), isFalse);

    final debugLog = AgentLog(
      temp,
      minimumLevel: LogLevel.debug,
      clock: () => DateTime(2026, 8, 19),
    );
    debugLog.debug('jetzt schon');
    expect(debugLog.file.readAsLinesSync(), hasLength(1));
  });

  test('mehrzeilige Nachrichten bleiben eine Zeile', () {
    final log = AgentLog(temp, clock: () => DateTime(2026, 8, 19));
    log.warn('Zeile eins\nZeile zwei');
    expect(log.file.readAsLinesSync(), hasLength(1));
  });

  test('Ringpuffer hält die letzten 50 Fehler', () {
    final log = AgentLog(temp, clock: () => DateTime(2026, 8, 19));
    for (var i = 0; i < 60; i++) {
      log.error('Fehler $i');
    }
    log.info('kein Fehler');

    final errors = log.recentErrors;
    expect(errors, hasLength(50));
    expect(errors.first.message, 'Fehler 10');
    expect(errors.last.message, 'Fehler 59');
    expect(errors.every((e) => e.level == LogLevel.error), isTrue);
    expect(errors.last.toJson()['level'], 'error');
  });

  test('Ringpuffer ist von außen nicht änderbar', () {
    final log = AgentLog(temp, clock: () => DateTime(2026, 8, 19));
    log.error('eins');
    expect(
      () => log.recentErrors.add(LogEntry(DateTime(2026), LogLevel.error, 'x')),
      throwsUnsupportedError,
    );
  });

  test('rotiert bei Tageswechsel und hält 7 Dateien', () {
    var now = DateTime(2026, 8, 1, 9);
    final log = AgentLog(temp, clock: () => now);

    for (var day = 1; day <= 12; day++) {
      now = DateTime(2026, 8, day, 9);
      log.info('Tag $day');
    }

    final archives = archiveNames(temp);
    expect(log.file.existsSync(), isTrue);
    expect(log.file.readAsStringSync(), contains('Tag 12'));
    expect(archives, hasLength(6), reason: 'aktuelle Datei plus 6 Archive = 7');
    expect(archives.first, 'connect-2026-08-06.log');
    expect(archives.last, 'connect-2026-08-11.log');
  });

  test('kein Tageswechsel, keine Rotation', () {
    var now = DateTime(2026, 8, 19, 8);
    final log = AgentLog(temp, clock: () => now);
    log.info('morgens');
    now = DateTime(2026, 8, 19, 23, 59);
    log.info('abends');

    expect(archiveNames(temp), isEmpty);
    expect(log.file.readAsLinesSync(), hasLength(2));
  });

  test('setzt den Tag beim Start aus der vorhandenen Datei fort', () {
    final existing = File(p.join(temp.path, 'connect.log'))
      ..writeAsStringSync('alt\n')
      ..setLastModifiedSync(DateTime(2026, 8, 18, 12));

    final log = AgentLog(temp, clock: () => DateTime(2026, 8, 19, 8));
    log.info('neuer Tag');

    expect(archiveNames(temp), <String>['connect-2026-08-18.log']);
    expect(
      File(p.join(temp.path, 'connect-2026-08-18.log')).readAsStringSync(),
      'alt\n',
    );
    expect(existing.readAsStringSync(), contains('neuer Tag'));
  });

  test('legt das Logverzeichnis an', () {
    final nested = Directory(p.join(temp.path, 'logs'));
    AgentLog(nested, clock: () => DateTime(2026, 8, 19)).info('da');
    expect(nested.existsSync(), isTrue);
  });
}
