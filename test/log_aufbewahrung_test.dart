import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

LogArchiv _a(String name, [int bytes = 1]) => LogArchiv.ausName(name, bytes)!;

void main() {
  group('Archivnamen', () {
    test('Tagesdatei und Teile werden erkannt, alles andere nicht', () {
      expect(_a('connect-2026-11-10.log').teil, isNull);
      expect(_a('connect-2026-11-10-3.log').teil, 3);
      expect(_a('connect-2026-11-10-3.log').tag, '2026-11-10');
      for (final fremd in <String>[
        'connect.log',
        'launchd.out.log',
        'connect-2026-11-10.txt',
        'connect-2026-11-1.log',
        'connect-2026-11-10-.log',
      ]) {
        expect(LogArchiv.ausName(fremd, 1), isNull, reason: fremd);
      }
    });

    test('zeitliche Reihenfolge: Teile nach Nummer, Tagesdatei zuletzt', () {
      final liste = <LogArchiv>[
        _a('connect-2026-11-10.log'),
        _a('connect-2026-11-10-10.log'),
        _a('connect-2026-11-09.log'),
        _a('connect-2026-11-10-2.log'),
      ]..sort(LogArchiv.chronologisch);
      expect(liste.map((a) => a.name), <String>[
        'connect-2026-11-09.log',
        'connect-2026-11-10-2.log',
        'connect-2026-11-10-10.log',
        'connect-2026-11-10.log',
      ]);
    });

    test('nächster freier Teil', () {
      expect(naechsterTeilName('2026-11-10', <String>[]), endsWith('-1.log'));
      expect(
        naechsterTeilName('2026-11-10', <String>[
          'connect-2026-11-10-1.log',
          'connect-2026-11-10-2.log',
        ]),
        'connect-2026-11-10-3.log',
      );
    });
  });

  group('zuLoeschendeArchive', () {
    test('nur die letzten Tage bleiben, der laufende Tag immer', () {
      final weg = zuLoeschendeArchive(
        <LogArchiv>[
          for (var tag = 1; tag <= 9; tag++) _a('connect-2026-11-0$tag.log'),
          _a('connect-2026-11-10-1.log'),
        ],
        maxTage: 6,
        aktuellerTag: '2026-11-10',
        aktuelleBytes: 0,
      );
      expect(weg, <String>[
        'connect-2026-11-01.log',
        'connect-2026-11-02.log',
        'connect-2026-11-03.log',
      ]);
    });

    test('über der Gesamtgrenze geht die älteste zuerst', () {
      final weg = zuLoeschendeArchive(
        <LogArchiv>[
          _a('connect-2026-11-10-2.log', 40),
          _a('connect-2026-11-09.log', 40),
          _a('connect-2026-11-10-1.log', 40),
        ],
        maxTage: 6,
        aktuellerTag: '2026-11-10',
        aktuelleBytes: 30,
        maxGesamtBytes: 100,
      );
      expect(weg, <String>[
        'connect-2026-11-09.log',
        'connect-2026-11-10-1.log',
      ]);
    });

    test('ohne Archive nichts zu tun', () {
      expect(
        zuLoeschendeArchive(
          const <LogArchiv>[],
          maxTage: 6,
          aktuellerTag: '2026-11-10',
          aktuelleBytes: 1 << 30,
        ),
        isEmpty,
      );
    });
  });

  group('Logger mit Größengrenze', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('connect-loggr-'));
    tearDown(() => temp.deleteSync(recursive: true));

    List<String> dateien() =>
        temp
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .toList()
          ..sort();

    int gesamt() => temp.listSync().whereType<File>().fold<int>(
      0,
      (s, f) => s + f.lengthSync(),
    );

    test('eine volle Datei wandert in den nächsten Teil desselben Tages', () {
      final log = AgentLog(
        temp,
        clock: () => DateTime(2026, 11, 10, 9),
        maxFileBytes: 200,
        maxTotalBytes: 100000,
      );
      for (var i = 0; i < 12; i++) {
        log.info('Zeile $i mit etwas Text, damit sie zählt');
      }
      final namen = dateien();
      expect(namen, contains('connect.log'));
      expect(namen, contains('connect-2026-11-10-1.log'));
      expect(namen, contains('connect-2026-11-10-2.log'));
      for (final name in namen) {
        expect(
          File(p.join(temp.path, name)).lengthSync(),
          lessThanOrEqualTo(200),
          reason: name,
        );
      }
      // Keine Zeile geht verloren.
      final zeilen = namen
          .expand((n) => File(p.join(temp.path, n)).readAsLinesSync())
          .toList();
      expect(zeilen, hasLength(12));
    });

    test('alle Dateien zusammen bleiben unter der Gesamtgrenze', () {
      final log = AgentLog(
        temp,
        clock: () => DateTime(2026, 11, 10, 9),
        maxFileBytes: 200,
        maxTotalBytes: 1000,
      );
      for (var i = 0; i < 200; i++) {
        log.info('Zeile $i mit etwas Text, damit sie zählt');
      }
      expect(gesamt(), lessThanOrEqualTo(1000 + 200));
      final letzte = log.file.readAsLinesSync().last;
      expect(letzte, endsWith('Zeile 199 mit etwas Text, damit sie zählt'));
    });

    test('Tageswechsel nach Teilen: die Tagesdatei schließt den Tag ab', () {
      var jetzt = DateTime(2026, 11, 9, 9);
      final log = AgentLog(
        temp,
        clock: () => jetzt,
        maxFileBytes: 200,
        maxTotalBytes: 100000,
      );
      for (var i = 0; i < 6; i++) {
        log.info('Zeile $i mit etwas Text, damit sie zählt');
      }
      jetzt = DateTime(2026, 11, 10, 9);
      log.info('neuer Tag');
      expect(
        dateien(),
        containsAll(<String>[
          'connect-2026-11-09-1.log',
          'connect-2026-11-09.log',
          'connect.log',
        ]),
      );
      expect(log.file.readAsLinesSync().single, endsWith('neuer Tag'));
    });
  });

  group('launchd-Logs', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('connect-launchd-'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('restAnfang beginnt nach dem ersten Umbruch', () {
      expect(restAnfang(Uint8List.fromList('halb\nganz\n'.codeUnits)), 5);
      expect(restAnfang(Uint8List.fromList('ohne Umbruch'.codeUnits)), 0);
    });

    test('über der Grenze bleibt nur das Ende, an einer Zeilengrenze', () {
      final datei = File(p.join(temp.path, 'launchd.err.log'));
      final zeilen = <String>[
        for (var i = 0; i < 1000; i++) 'Zeile ${i.toString().padLeft(4, '0')}',
      ];
      datei.writeAsStringSync('${zeilen.join('\n')}\n');
      final klein = File(p.join(temp.path, 'launchd.out.log'))
        ..writeAsStringSync('klein\n');

      kuerzeLaunchdLogs(temp, grenze: 1000, rest: 300);

      final rest = datei.readAsStringSync();
      expect(rest.length, lessThanOrEqualTo(300));
      expect(rest, endsWith('Zeile 0999\n'));
      expect(rest.split('\n').first, matches(RegExp(r'^Zeile \d{4}$')));
      expect(klein.readAsStringSync(), 'klein\n', reason: 'unter der Grenze');
    });

    // launchd öffnet die Datei mit O_APPEND. Dart kann das nicht
    // (FileMode.append setzt nur die Position ans Ende), die Shell mit `>>`
    // schon – darum hält hier eine Shell den Schreiber offen.
    test(
      'ein offener Schreiber mit O_APPEND schreibt hinter den Rest',
      () async {
        final datei = File(p.join(temp.path, 'launchd.out.log'))
          ..writeAsStringSync('${'x' * 2000}\nende\n');
        final offen = File(p.join(temp.path, 'offen'));
        final weiter = File(p.join(temp.path, 'weiter'));
        final shell = await Process.start('bash', <String>[
          '-c',
          r'exec 3>>"$1"; : > "$2"; '
              r'while [ ! -f "$3" ]; do sleep 0.02; done; echo danach >&3',
          'schreiber',
          datei.path,
          offen.path,
          weiter.path,
        ]);
        while (!offen.existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        kuerzeLaunchdLogs(temp, grenze: 1000, rest: 100);
        weiter.writeAsStringSync('');
        expect(await shell.exitCode, 0);
        expect(datei.readAsStringSync(), 'ende\ndanach\n');
      },
      testOn: '!windows',
    );

    test('nicht lesbare Datei: Logzeile, kein Abbruch', () {
      // Als root sind Rechte wirkungslos – dann gibt es nichts zu prüfen.
      if ('${Process.runSync('id', <String>['-u']).stdout}'.trim() == '0') {
        markTestSkipped('läuft als root');
        return;
      }
      final datei = File(p.join(temp.path, 'launchd.err.log'))
        ..writeAsStringSync('x' * 2000);
      Process.runSync('chmod', <String>['000', datei.path]);
      addTearDown(() => Process.runSync('chmod', <String>['600', datei.path]));
      final log = AgentLog(Directory(p.join(temp.path, 'logs')));
      expect(
        () => kuerzeLaunchdLogs(temp, log: log, grenze: 1000, rest: 100),
        returnsNormally,
      );
      expect(log.file.readAsStringSync(), contains('ließ sich nicht kürzen'));
    }, testOn: '!windows');

    test('fehlende Dateien stören nicht', () {
      expect(() => kuerzeLaunchdLogs(temp), returnsNormally);
    });
  });
}
