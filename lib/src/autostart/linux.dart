import 'dart:io';

import 'package:path/path.dart' as p;

import '../process_runner.dart';
import 'autostart.dart';

/// Baut die systemd-Unit des Agenten.
///
/// `--user`-Unit statt Systemdienst: der Agent gehört zur angemeldeten
/// Sitzung. `Restart=always` entspricht `KeepAlive` unter macOS, und
/// `WantedBy=default.target` startet ihn bei der Anmeldung.
///
/// Kein `After=network-online.target`: das ist ein Ziel der **System**-Instanz
/// und in einer User-Unit wirkungslos. Der Agent braucht es auch nicht — er
/// bindet nur die Loopback-Adresse und sucht Drucker erst auf Zuruf.
///
/// Der Pfad in `ExecStart` steht in Anführungszeichen, sonst zerlegt systemd
/// ihn am Leerzeichen.
String systemdUnit(String executable) =>
    '''
[Unit]
Description=Kasseneck Connect — lokaler Agent der Kasseneck-Kasse

[Service]
Type=simple
ExecStart="$executable" run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
''';

/// Autostart über eine systemd-User-Unit.
class LinuxAutostart implements Autostart {
  LinuxAutostart({
    required Map<String, String> environment,
    required this.executable,
    required ProcessRunner runProcess,
  }) : _environment = environment,
       _runProcess = runProcess;

  final String executable;
  final Map<String, String> _environment;
  final ProcessRunner _runProcess;

  /// `~/.config/systemd/user/kasseneck-connect.service`.
  File get unitFile {
    final xdg = _environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.trim().isNotEmpty)
        ? xdg.trim()
        : p.join(_environment['HOME'] ?? '', '.config');
    return File(p.join(base, 'systemd', 'user', autostartUnitName));
  }

  @override
  String get target => unitFile.path;

  @override
  Future<bool> isInstalled() async => unitFile.existsSync();

  @override
  Future<AutostartResult> install() async {
    try {
      await unitFile.parent.create(recursive: true);
      await unitFile.writeAsString(systemdUnit(executable));
    } on FileSystemException catch (e) {
      return AutostartResult.failure(
        'Die systemd-Unit ließ sich nicht schreiben.',
        detail: e.message,
      );
    }

    await _systemctl(<String>['--user', 'daemon-reload']);
    final enabled = await _systemctl(<String>[
      '--user',
      'enable',
      '--now',
      autostartUnitName,
    ]);
    if (enabled?.exitCode != 0) {
      return AutostartResult.failure(
        'systemctl konnte den Autostart nicht aktivieren.',
        detail: _detailOf(enabled),
      );
    }
    return AutostartResult.success('Autostart eingerichtet: ${unitFile.path}');
  }

  @override
  Future<AutostartResult> uninstall() async {
    await _systemctl(<String>['--user', 'disable', '--now', autostartUnitName]);
    try {
      if (unitFile.existsSync()) await unitFile.delete();
    } on FileSystemException catch (e) {
      return AutostartResult.failure(
        'Die systemd-Unit ließ sich nicht löschen.',
        detail: e.message,
      );
    }
    await _systemctl(<String>['--user', 'daemon-reload']);
    return const AutostartResult.success('Autostart entfernt.');
  }

  Future<ProcessResult?> _systemctl(List<String> arguments) async {
    try {
      return await _runProcess('systemctl', arguments);
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
