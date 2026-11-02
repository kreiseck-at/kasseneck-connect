import 'dart:io';

import '../process_runner.dart';

/// Team-ID von Post Now e.U. im Apple Developer Program – das Paket muss mit
/// einer Developer-ID-Installer-Identität dieses Teams signiert sein.
///
/// Geprüft wird die Team-ID, nicht ein einzelnes Zertifikat: ein erneuertes
/// Zertifikat (das heutige läuft 2027-02-01 ab) bricht die Aktualisierung so
/// nicht.
const String connectTeamId = '6KMT4H4CNE';

final RegExp _installerLeaf = RegExp(
  r'^\s*1\.\s+Developer ID Installer: .+ \(' + connectTeamId + r'\)\s*$',
  multiLine: true,
);
final RegExp _appleRoot = RegExp(
  r'^\s*\d+\.\s+Apple Root CA\s*$',
  multiLine: true,
);
final RegExp _notarizedOrigin = RegExp(
  r'^origin=Developer ID Installer: .+ \(' + connectTeamId + r'\)\s*$',
  multiLine: true,
);

/// Ob [pkg] nachweislich unser notarisiertes Installationspaket ist.
///
/// `pkgutil --check-signature`: gültige Signatur, das Blatt der Kette
/// (`1.`) ist „Developer ID Installer“ unseres Teams, die Kette endet bei
/// „Apple Root CA“. `spctl -a -t install`: Gatekeeper nimmt das Paket an als
/// „Notarized Developer ID“ unseres Teams. Wirft nie.
Future<bool> verifyMacPackage(File pkg, {required ProcessRunner run}) async {
  final signature = await _output(run, 'pkgutil', <String>[
    '--check-signature',
    pkg.path,
  ]);
  if (signature == null ||
      !signature.contains(
        'Status: signed by a developer certificate issued by Apple for distribution',
      ) ||
      !_installerLeaf.hasMatch(signature) ||
      !_appleRoot.hasMatch(signature)) {
    return false;
  }
  final gatekeeper = await _output(run, 'spctl', <String>[
    '-a',
    '-t',
    'install',
    '-vv',
    pkg.path,
  ]);
  return gatekeeper != null &&
      gatekeeper.contains('source=Notarized Developer ID') &&
      _notarizedOrigin.hasMatch(gatekeeper);
}

/// stdout und stderr zusammen, `null` bei Exit-Code ≠ 0 oder Startfehler.
Future<String?> _output(
  ProcessRunner run,
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await run(executable, arguments);
    if (result.exitCode != 0) return null;
    return '${result.stdout}\n${result.stderr}';
  } on Object {
    return null;
  }
}
