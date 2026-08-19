import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/paths.dart';
import '../process_runner.dart';
import 'autostart.dart';

/// Dateiname des LaunchAgents.
const String launchAgentFileName = '$autostartLabel.plist';

/// Baut die Plist des LaunchAgents.
///
/// `RunAtLoad` startet den Agenten bei der Anmeldung, `KeepAlive` bringt ihn
/// nach einem Absturz von selbst zurück. Ausgabe und Fehler landen neben dem
/// eigenen Log im Datenverzeichnis — wenn der Agent so früh stirbt, dass er
/// sein Log nicht mehr schreibt, steht der Grund dort.
String launchAgentPlist({
  required String executable,
  required Directory logDirectory,
}) {
  final out = p.join(logDirectory.path, 'launchd.out.log');
  final err = p.join(logDirectory.path, 'launchd.err.log');
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$autostartLabel</string>
	<key>ProgramArguments</key>
	<array>
		<string>${escapeXml(executable)}</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>${escapeXml(out)}</string>
	<key>StandardErrorPath</key>
	<string>${escapeXml(err)}</string>
</dict>
</plist>
''';
}

/// Maskiert die fünf XML-Sonderzeichen — ein `&` im Pfad zerlegte sonst die
/// Plist.
String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Autostart über einen LaunchAgent im Benutzerkontext.
///
/// Bewusst **kein** LaunchDaemon: der Agent gehört zur angemeldeten Sitzung,
/// braucht keine Systemrechte und liest seine Konfiguration aus dem
/// Benutzerverzeichnis.
class MacosAutostart implements Autostart {
  MacosAutostart({
    required Map<String, String> environment,
    required this.paths,
    required this.executable,
    required ProcessRunner runProcess,
  }) : _environment = environment,
       _runProcess = runProcess;

  final ConfigPaths paths;
  final String executable;
  final Map<String, String> _environment;
  final ProcessRunner _runProcess;

  /// `~/Library/LaunchAgents/at.kasseneck.connect.plist`.
  File get plistFile => File(
    p.join(
      _environment['HOME'] ?? '',
      'Library',
      'LaunchAgents',
      launchAgentFileName,
    ),
  );

  @override
  String get target => plistFile.path;

  @override
  Future<bool> isInstalled() async => plistFile.existsSync();

  @override
  Future<AutostartResult> install() async {
    final uid = await _userId();
    if (uid == null) {
      return const AutostartResult.failure(
        'Benutzerkennung ließ sich nicht ermitteln (id -u).',
      );
    }

    try {
      await plistFile.parent.create(recursive: true);
      await paths.logDirectory.create(recursive: true);
      await plistFile.writeAsString(
        launchAgentPlist(
          executable: executable,
          logDirectory: paths.logDirectory,
        ),
      );
    } on FileSystemException catch (e) {
      return AutostartResult.failure(
        'Der LaunchAgent ließ sich nicht schreiben.',
        detail: e.message,
      );
    }

    // Eine ältere Fassung muss weg, sonst weist `bootstrap` sie als bereits
    // geladen ab.
    await _launchctl(<String>['bootout', 'gui/$uid/$autostartLabel']);

    final bootstrap = await _launchctl(<String>[
      'bootstrap',
      'gui/$uid',
      plistFile.path,
    ]);
    if (bootstrap?.exitCode == 0) {
      return AutostartResult.success(
        'Autostart eingerichtet: ${plistFile.path}',
      );
    }

    // Ältere macOS-Fassungen kennen `bootstrap` noch nicht.
    final legacy = await _launchctl(<String>['load', '-w', plistFile.path]);
    if (legacy?.exitCode == 0) {
      return AutostartResult.success(
        'Autostart eingerichtet: ${plistFile.path}',
      );
    }

    return AutostartResult.failure(
      'launchctl konnte den Autostart nicht laden.',
      detail: _detailOf(bootstrap) ?? _detailOf(legacy),
    );
  }

  @override
  Future<AutostartResult> uninstall() async {
    final uid = await _userId();
    if (uid != null) {
      final bootout = await _launchctl(<String>[
        'bootout',
        'gui/$uid/$autostartLabel',
      ]);
      if (bootout?.exitCode != 0) {
        await _launchctl(<String>['unload', '-w', plistFile.path]);
      }
    }

    try {
      if (plistFile.existsSync()) await plistFile.delete();
    } on FileSystemException catch (e) {
      return AutostartResult.failure(
        'Der LaunchAgent ließ sich nicht löschen.',
        detail: e.message,
      );
    }
    return const AutostartResult.success('Autostart entfernt.');
  }

  /// Numerische Kennung des angemeldeten Benutzers für `gui/<uid>`.
  ///
  /// Dart kennt kein `getuid()`; `id -u` ist der kürzeste verlässliche Weg.
  Future<String?> _userId() async {
    try {
      final result = await _runProcess('id', <String>['-u']);
      if (result.exitCode != 0) return null;
      final uid = '${result.stdout}'.trim();
      return RegExp(r'^\d+$').hasMatch(uid) ? uid : null;
    } on ProcessException {
      return null;
    }
  }

  Future<ProcessResult?> _launchctl(List<String> arguments) async {
    try {
      return await _runProcess('launchctl', arguments);
    } on ProcessException {
      return null;
    }
  }

  static String? _detailOf(ProcessResult? result) {
    if (result == null) return null;
    final text = '${result.stderr}'.trim();
    return text.isEmpty ? null : text;
  }
}
