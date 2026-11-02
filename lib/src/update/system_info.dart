import 'dart:io';

import '../process_runner.dart';

/// Längste Angabe, die als Systemversion oder Prozessor durchgeht – was
/// länger ist, ist keine ordentliche Antwort des Programms.
const int _maxLength = 32;

/// Betriebssystem, dessen Version und der Prozessor des Rechners.
///
/// Für die Langform von `GET /v1/status`: die Kasse meldet diese Angaben an
/// Kasseneck (Bestand: wer hat welche Connect-Version auf welchem System).
/// Bewusst nichts, was den Rechner oder Menschen benennt.
class SystemInfo {
  const SystemInfo({required this.os, this.osVersion, this.arch});

  /// `macos`, `windows`, `linux` (wie `Platform.operatingSystem`).
  final String os;

  /// z. B. `26.5.1`; `null`, wenn unbekannt.
  final String? osVersion;

  /// z. B. `arm64`, `x86_64`; `null`, wenn unbekannt.
  final String? arch;

  Map<String, Object?> toJson() => <String, Object?>{
    'os': os,
    'osVersion': osVersion,
    'arch': arch,
  };
}

/// Liest die Systemangaben. Wirft nie: was sich nicht lesen lässt, bleibt
/// `null`.
///
/// macOS: `sw_vers -productVersion` und `uname -m`; Linux: `uname -r` und
/// `uname -m`; Windows: die Versionszeile von Dart (`Platform.
/// operatingSystemVersion`) und die Umgebungsvariable des Prozessors.
Future<SystemInfo> readSystemInfo({
  required ProcessRunner run,
  String? operatingSystem,
  Map<String, String>? environment,
}) async {
  final os = operatingSystem ?? Platform.operatingSystem;
  switch (os) {
    case 'macos':
      return SystemInfo(
        os: os,
        osVersion: await _line(run, 'sw_vers', <String>['-productVersion']),
        arch: await _line(run, 'uname', <String>['-m']),
      );
    case 'linux':
      return SystemInfo(
        os: os,
        osVersion: await _line(run, 'uname', <String>['-r']),
        arch: await _line(run, 'uname', <String>['-m']),
      );
    default:
      final env = environment ?? Platform.environment;
      return SystemInfo(
        os: os,
        osVersion: _clean(Platform.operatingSystemVersion),
        arch: _clean(env['PROCESSOR_ARCHITECTURE']?.toLowerCase()),
      );
  }
}

Future<String?> _line(
  ProcessRunner run,
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await run(executable, arguments);
    if (result.exitCode != 0) return null;
    return _clean('${result.stdout}');
  } on Object {
    return null;
  }
}

String? _clean(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty || text.length > _maxLength) return null;
  return text;
}
