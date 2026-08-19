import 'dart:io';

import '../config/paths.dart';
import '../process_runner.dart';
import 'linux.dart';
import 'macos.dart';
import 'windows.dart';

/// Bezeichner des Autostart-Eintrags (macOS-Label, Windows-Aufgabenname,
/// systemd-Unit leiten sich davon ab).
const String autostartLabel = 'at.kasseneck.connect';

/// Name der Aufgabe in der Windows-Aufgabenplanung.
const String autostartTaskName = 'Kasseneck Connect';

/// Name der systemd-Unit unter Linux.
const String autostartUnitName = 'kasseneck-connect.service';

/// Ergebnis von [Autostart.install] bzw. [Autostart.uninstall].
class AutostartResult {
  const AutostartResult({required this.ok, required this.message, this.detail});

  const AutostartResult.success(this.message) : ok = true, detail = null;

  const AutostartResult.failure(this.message, {this.detail}) : ok = false;

  /// Ob der Schritt geklappt hat.
  final bool ok;

  /// Deutscher Klartext für die Konsole.
  final String message;

  /// Zusatz für die Fehlersuche (Kommandoausgabe), sonst `null`.
  final String? detail;

  @override
  String toString() => ok ? 'ok: $message' : 'Fehler: $message';
}

/// Autostart des Agenten — je Betriebssystem ein eigener Weg.
///
/// Der Pfad zur Binary ist `Platform.resolvedExecutable`: die kompilierte
/// Binary trägt sich also selbst ein. Läuft der Agent ausnahmsweise über
/// `dart run`, stünde dort der Dart-Interpreter — deshalb ist [executable]
/// überschreibbar (Installer, Tests).
abstract class Autostart {
  /// Wohin der Eintrag geschrieben wird (Plist-Pfad, Aufgabenname, Unit-Pfad).
  String get target;

  /// Ob der Eintrag vorhanden ist.
  Future<bool> isInstalled();

  /// Legt den Eintrag an und startet den Agenten.
  Future<AutostartResult> install();

  /// Entfernt den Eintrag und hält den Agenten an.
  Future<AutostartResult> uninstall();
}

/// Der Autostart des laufenden Systems.
///
/// [operatingSystem], [environment], [runProcess] und [executable] sind
/// Nahtstellen: im Test läuft nie ein echtes `launchctl`.
Autostart autostartForPlatform({
  String? operatingSystem,
  Map<String, String>? environment,
  ConfigPaths? paths,
  ProcessRunner? runProcess,
  String? executable,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final resolvedPaths =
      paths ?? ConfigPaths.forPlatform(environment: env, operatingSystem: os);
  final binary = executable ?? Platform.resolvedExecutable;
  final runner = runProcess ?? Process.run;

  switch (os) {
    case 'macos':
      return MacosAutostart(
        environment: env,
        paths: resolvedPaths,
        executable: binary,
        runProcess: runner,
      );
    case 'windows':
      return WindowsAutostart(executable: binary, runProcess: runner);
    default:
      return LinuxAutostart(
        environment: env,
        executable: binary,
        runProcess: runner,
      );
  }
}
