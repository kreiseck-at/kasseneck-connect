import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

void main() {
  late Directory temp;
  late Directory home;
  late ConfigPaths paths;
  late FakeProcessRunner runner;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-autostart-');
    home = Directory(p.join(temp.path, 'home'))..createSync(recursive: true);
    paths = ConfigPaths(Directory(p.join(temp.path, 'daten')));
    runner = FakeProcessRunner()..stdoutOf['-u'] = '501\n';
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, String> env() => <String, String>{'HOME': home.path};

  MacosAutostart macos({String executable = '/usr/local/bin/connect'}) =>
      MacosAutostart(
        environment: env(),
        paths: paths,
        executable: executable,
        runProcess: runner.runner,
      );

  WindowsAutostart windows({
    String executable = r'C:\Users\Kasse\Connect\kasseneck-connect.exe',
  }) => WindowsAutostart(executable: executable, runProcess: runner.runner);

  LinuxAutostart linux({
    String executable = '/opt/connect/kasseneck-connect',
  }) => LinuxAutostart(
    environment: env(),
    executable: executable,
    runProcess: runner.runner,
  );

  group('macOS — Plist', () {
    test('trägt Label, Binary und `run` ein', () {
      final plist = launchAgentPlist(
        executable: '/usr/local/kasseneck-connect/kasseneck-connect',
        logDirectory: paths.logDirectory,
      );

      expect(plist, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(plist, contains('<key>Label</key>'));
      expect(plist, contains('<string>at.kasseneck.connect</string>'));
      expect(
        plist,
        contains(
          '<string>/usr/local/kasseneck-connect/kasseneck-connect</string>\n'
          '\t\t<string>run</string>',
        ),
      );
    });

    test('startet bei der Anmeldung und kommt nach einem Absturz zurück', () {
      final plist = launchAgentPlist(
        executable: '/bin/connect',
        logDirectory: paths.logDirectory,
      );
      expect(plist, contains('<key>RunAtLoad</key>\n\t<true/>'));
      expect(plist, contains('<key>KeepAlive</key>\n\t<true/>'));
    });

    test('leitet Ausgabe und Fehler ins Logverzeichnis um', () {
      final plist = launchAgentPlist(
        executable: '/bin/connect',
        logDirectory: paths.logDirectory,
      );
      expect(
        plist,
        contains(
          '<string>${p.join(paths.logDirectory.path, 'launchd.out.log')}</string>',
        ),
      );
      expect(
        plist,
        contains(
          '<string>${p.join(paths.logDirectory.path, 'launchd.err.log')}</string>',
        ),
      );
    });

    test('maskiert Sonderzeichen im Pfad', () {
      final plist = launchAgentPlist(
        executable: '/Users/A & B/connect',
        logDirectory: paths.logDirectory,
      );
      expect(plist, contains('<string>/Users/A &amp; B/connect</string>'));
      expect(plist, isNot(contains('A & B')));
    });
  });

  group('macOS — Einrichten und Entfernen', () {
    test('schreibt die Plist und lädt sie über launchctl bootstrap', () async {
      final autostart = macos();
      final result = await autostart.install();

      expect(result.ok, isTrue, reason: result.detail);
      final plist = File(
        p.join(
          home.path,
          'Library',
          'LaunchAgents',
          'at.kasseneck.connect.plist',
        ),
      );
      expect(plist.existsSync(), isTrue);
      expect(plist.readAsStringSync(), contains('at.kasseneck.connect'));
      expect(
        runner.sawCall('launchctl', <String>[
          'bootstrap',
          'gui/501',
          plist.path,
        ]),
        isTrue,
        reason: runner.lines.join('\n'),
      );
      expect(await autostart.isInstalled(), isTrue);
    });

    test('wirft eine alte Fassung vor dem Laden hinaus', () async {
      await macos().install();
      final order = runner.lines.where((line) => line.startsWith('launchctl'));
      expect(order.first, 'launchctl bootout gui/501/at.kasseneck.connect');
      expect(order.elementAt(1), startsWith('launchctl bootstrap gui/501 '));
    });

    test('fällt auf launchctl load zurück, wenn bootstrap scheitert', () async {
      runner.exitCodes['bootstrap'] = 5;
      final result = await macos().install();

      expect(result.ok, isTrue);
      expect(runner.lines.last, endsWith('load -w ${macos().plistFile.path}'));
    });

    test('meldet einen Fehler, wenn beide Wege scheitern', () async {
      runner.exitCodes['bootstrap'] = 5;
      runner.exitCodes['load'] = 5;
      final result = await macos().install();

      expect(result.ok, isFalse);
      expect(result.message, contains('launchctl'));
    });

    test('ohne Benutzerkennung wird nichts geschrieben', () async {
      runner.exitCodes['-u'] = 1;
      final result = await macos().install();

      expect(result.ok, isFalse);
      expect(macos().plistFile.existsSync(), isFalse);
    });

    test('bootout und Löschen beim Entfernen', () async {
      final autostart = macos();
      await autostart.install();
      runner.calls.clear();

      final result = await autostart.uninstall();

      expect(result.ok, isTrue);
      expect(
        runner.sawCall('launchctl', <String>[
          'bootout',
          'gui/501/at.kasseneck.connect',
        ]),
        isTrue,
      );
      expect(autostart.plistFile.existsSync(), isFalse);
      expect(await autostart.isInstalled(), isFalse);
    });

    test('Entfernen ohne vorhandenen Eintrag ist in Ordnung', () async {
      final result = await macos().uninstall();
      expect(result.ok, isTrue);
    });
  });

  group('Windows', () {
    test('legt die Aufgabe bei Anmeldung mit LIMITED an', () {
      final args = schtasksCreateArguments(r'C:\Programme\connect.exe');
      expect(args, <String>[
        '/Create',
        '/F',
        '/SC',
        'ONLOGON',
        '/TN',
        'Kasseneck Connect',
        '/TR',
        r'"C:\Programme\connect.exe" run',
        '/RL',
        'LIMITED',
      ]);
    });

    test('der Pfad in /TR steht in Anführungszeichen', () {
      final args = schtasksCreateArguments(r'C:\Program Files\Kasseneck\c.exe');
      expect(args[args.indexOf('/TR') + 1], startsWith('"'));
      expect(args[args.indexOf('/TR') + 1], endsWith('" run'));
    });

    test('ein anders zerlegter Aufruf gilt nicht als Treffer', () async {
      // `['/TN Kasseneck', 'Connect']` ergibt dieselbe Zeile wie
      // `['/TN', 'Kasseneck Connect']`, ist als Aufruf aber etwas anderes.
      await runner.runner('schtasks', <String>['/TN Kasseneck', 'Connect']);
      expect(
        runner.sawCall('schtasks', <String>['/TN', 'Kasseneck Connect']),
        isFalse,
      );
    });

    test('Löschen erzwingt und nennt die Aufgabe', () {
      expect(schtasksDeleteArguments(), <String>[
        '/Delete',
        '/F',
        '/TN',
        'Kasseneck Connect',
      ]);
    });

    test('install ruft schtasks /Create und startet die Aufgabe', () async {
      final result = await windows().install();

      expect(result.ok, isTrue);
      expect(runner.calls.first.executable, 'schtasks');
      expect(runner.calls.first.arguments.first, '/Create');
      expect(runner.lines.last, 'schtasks /Run /TN Kasseneck Connect');
    });

    test('scheiterndes schtasks meldet einen Fehler', () async {
      runner.exitCodes['/Create'] = 1;
      final result = await windows().install();
      expect(result.ok, isFalse);
    });

    test('uninstall ruft schtasks /Delete', () async {
      final result = await windows().uninstall();
      expect(result.ok, isTrue);
      expect(runner.lines, <String>[
        'schtasks /Delete /F /TN Kasseneck Connect',
      ]);
    });

    test('isInstalled fragt die Aufgabenplanung', () async {
      expect(await windows().isInstalled(), isTrue);
      expect(runner.lines.last, 'schtasks /Query /TN Kasseneck Connect');

      runner.exitCodes['/Query'] = 1;
      expect(await windows().isInstalled(), isFalse);
    });
  });

  group('Linux', () {
    test('die Unit startet die Binary mit `run`', () {
      final unit = systemdUnit('/opt/connect/kasseneck-connect');
      expect(unit, contains('ExecStart="/opt/connect/kasseneck-connect" run'));
      expect(unit, contains('Restart=always'));
      expect(unit, contains('WantedBy=default.target'));
      expect(unit, contains('[Service]'));
    });

    test('der Pfad in ExecStart steht in Anführungszeichen', () {
      // Ohne Anführungszeichen zerlegt systemd den Pfad am Leerzeichen und
      // startet ein Programm, das es nicht gibt.
      final unit = systemdUnit('/opt/Kasseneck Connect/kasseneck-connect');
      expect(
        unit,
        contains('ExecStart="/opt/Kasseneck Connect/kasseneck-connect" run'),
      );
    });

    test('kein After=network-online.target in einer User-Unit', () {
      // Das Ziel gehört der System-Instanz und ist hier wirkungslos; der
      // Agent bindet ohnehin nur die Loopback-Adresse.
      expect(systemdUnit('/bin/connect'), isNot(contains('After=')));
      expect(systemdUnit('/bin/connect'), isNot(contains('network')));
    });

    test('schreibt die Unit nach ~/.config/systemd/user', () async {
      final autostart = linux();
      final result = await autostart.install();

      expect(result.ok, isTrue);
      expect(
        autostart.unitFile.path,
        p.join(
          home.path,
          '.config',
          'systemd',
          'user',
          'kasseneck-connect.service',
        ),
      );
      expect(autostart.unitFile.existsSync(), isTrue);
    });

    test('lädt systemd neu und aktiviert die Unit sofort', () async {
      await linux().install();
      expect(runner.lines, <String>[
        'systemctl --user daemon-reload',
        'systemctl --user enable --now kasseneck-connect.service',
      ]);
    });

    test('XDG_CONFIG_HOME schlägt HOME', () async {
      final xdg = Directory(p.join(temp.path, 'xdg'));
      final autostart = LinuxAutostart(
        environment: <String, String>{
          'HOME': home.path,
          'XDG_CONFIG_HOME': xdg.path,
        },
        executable: '/bin/connect',
        runProcess: runner.runner,
      );
      expect(autostart.unitFile.path, startsWith(xdg.path));
    });

    test('uninstall schaltet ab und löscht die Unit', () async {
      final autostart = linux();
      await autostart.install();
      runner.calls.clear();

      final result = await autostart.uninstall();

      expect(result.ok, isTrue);
      expect(
        runner.lines.first,
        'systemctl --user disable --now kasseneck-connect.service',
      );
      expect(autostart.unitFile.existsSync(), isFalse);
    });

    test('scheiterndes enable meldet einen Fehler', () async {
      runner.exitCodes['--user'] = 1;
      final result = await linux().install();
      expect(result.ok, isFalse);
    });
  });

  group('Auswahl je Betriebssystem', () {
    test('macOS, Windows und Linux bekommen ihren eigenen Weg', () {
      expect(
        autostartForPlatform(
          operatingSystem: 'macos',
          environment: env(),
          paths: paths,
          runProcess: runner.runner,
          executable: '/bin/connect',
        ),
        isA<MacosAutostart>(),
      );
      expect(
        autostartForPlatform(
          operatingSystem: 'windows',
          environment: env(),
          paths: paths,
          runProcess: runner.runner,
          executable: r'C:\c.exe',
        ),
        isA<WindowsAutostart>(),
      );
      expect(
        autostartForPlatform(
          operatingSystem: 'linux',
          environment: env(),
          paths: paths,
          runProcess: runner.runner,
          executable: '/bin/connect',
        ),
        isA<LinuxAutostart>(),
      );
    });

    test('ein fehlendes Programm bleibt eine Fehlermeldung', () async {
      runner.missing.add('launchctl');
      final result = await macos().install();
      expect(result.ok, isFalse);
      expect(result.message, contains('launchctl'));
    });
  });
}
