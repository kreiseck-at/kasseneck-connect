import 'dart:io';

import '../process_runner.dart';
import 'autostart.dart';

/// Argumente für `schtasks /Create`.
///
/// `/SC ONLOGON` heißt „bei der Anmeldung", `/F` überschreibt eine vorhandene
/// Aufgabe, und `/RL LIMITED` lässt den Agenten mit den normalen Rechten des
/// Benutzers laufen — er braucht keine erhöhten. Der Pfad steht in `/TR` in
/// Anführungszeichen, sonst zerlegt die Aufgabenplanung ihn am Leerzeichen
/// (`C:\Program Files\…`).
List<String> schtasksCreateArguments(String executable) => <String>[
  '/Create',
  '/F',
  '/SC',
  'ONLOGON',
  '/TN',
  autostartTaskName,
  '/TR',
  '"$executable" run',
  '/RL',
  'LIMITED',
];

/// Argumente für `schtasks /Delete`.
List<String> schtasksDeleteArguments() => <String>[
  '/Delete',
  '/F',
  '/TN',
  autostartTaskName,
];

/// Argumente für `schtasks /Query` (Zustandsabfrage).
List<String> schtasksQueryArguments() => <String>[
  '/Query',
  '/TN',
  autostartTaskName,
];

/// Argumente für `schtasks /Run` (Agent sofort starten).
List<String> schtasksRunArguments() => <String>[
  '/Run',
  '/TN',
  autostartTaskName,
];

/// Autostart über die Windows-Aufgabenplanung („Bei Anmeldung").
///
/// Ein echter Dienst wäre robuster, bräuchte aber Administratorrechte und
/// hätte keine Benutzersitzung — der Agent gehört zur angemeldeten Kassenkraft.
/// Der Dienst ist als Ausbaustufe v1.2 vorgesehen.
class WindowsAutostart implements Autostart {
  WindowsAutostart({
    required this.executable,
    required ProcessRunner runProcess,
  }) : _runProcess = runProcess;

  final String executable;
  final ProcessRunner _runProcess;

  @override
  String get target => 'Aufgabenplanung: $autostartTaskName';

  @override
  Future<bool> isInstalled() async {
    final result = await _schtasks(schtasksQueryArguments());
    return result?.exitCode == 0;
  }

  @override
  Future<AutostartResult> install() async {
    final created = await _schtasks(schtasksCreateArguments(executable));
    if (created == null) {
      return const AutostartResult.failure('schtasks ließ sich nicht starten.');
    }
    if (created.exitCode != 0) {
      return AutostartResult.failure(
        'Die Aufgabe ließ sich nicht anlegen.',
        detail: _detailOf(created),
      );
    }
    // Ohne `/Run` liefe der Agent erst nach der nächsten Anmeldung.
    await _schtasks(schtasksRunArguments());
    return const AutostartResult.success(
      'Autostart eingerichtet (Aufgabenplanung: $autostartTaskName).',
    );
  }

  @override
  Future<AutostartResult> uninstall() async {
    final deleted = await _schtasks(schtasksDeleteArguments());
    if (deleted == null) {
      return const AutostartResult.failure('schtasks ließ sich nicht starten.');
    }
    if (deleted.exitCode != 0) {
      return AutostartResult.failure(
        'Die Aufgabe ließ sich nicht entfernen.',
        detail: _detailOf(deleted),
      );
    }
    return const AutostartResult.success('Autostart entfernt.');
  }

  Future<ProcessResult?> _schtasks(List<String> arguments) async {
    try {
      return await _runProcess('schtasks', arguments);
    } on ProcessException {
      return null;
    }
  }

  static String? _detailOf(ProcessResult result) {
    final text = '${result.stderr}'.trim();
    return text.isEmpty ? null : text;
  }
}
