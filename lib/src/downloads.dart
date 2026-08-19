/// Dateinamen der Auslieferung — die einzige Quelle für alle Beteiligten.
///
/// Die Kasse verlinkt im Download-Abschnitt **feste** Adressen unter
/// `connect/latest/`; wenn sich hier ein Name ändert, laufen diese Links ins
/// Leere. Deshalb stehen die Namen als Konstanten hier, `tool/release.sh`
/// baut genau sie, die README führt sie in einer Tabelle — und
/// `test/downloads_test.dart` nagelt alle drei gegeneinander fest.
library;

/// Namensrumpf jeder ausgelieferten Datei.
const String downloadPrefix = 'KasseneckConnect';

/// Plattformschlüssel → Dateiname unter `connect/latest/` (ohne Version).
///
/// Die Schlüssel sind zugleich die Schlüssel in `connect/latest.json`.
const Map<String, String> downloadLatestNames = <String, String>{
  'darwin-arm64': 'KasseneckConnect-macos-arm64.pkg',
  'darwin-x64': 'KasseneckConnect-macos-x64.pkg',
  'windows-x64': 'KasseneckConnect-windows-x64.exe',
  'linux-x64': 'KasseneckConnect-linux-x64.deb',
};

/// Betriebssystem und Architektur je Plattformschlüssel, so wie sie im
/// Dateinamen stehen (`macos`, `windows`, `linux` × `arm64`, `x64`).
const Map<String, String> downloadPlatformSuffix = <String, String>{
  'darwin-arm64': 'macos-arm64',
  'darwin-x64': 'macos-x64',
  'windows-x64': 'windows-x64',
  'linux-x64': 'linux-x64',
};

/// Dateiendung je Plattformschlüssel.
const Map<String, String> downloadExtension = <String, String>{
  'darwin-arm64': 'pkg',
  'darwin-x64': 'pkg',
  'windows-x64': 'exe',
  'linux-x64': 'deb',
};

/// Der versionierte Name, unter dem die Datei in `connect/<version>/` liegt.
///
/// `KasseneckConnect-0.1.0-macos-arm64.pkg`
String versionedDownloadName(String platformKey, String version) {
  final suffix = downloadPlatformSuffix[platformKey];
  final extension = downloadExtension[platformKey];
  if (suffix == null || extension == null) {
    throw ArgumentError.value(platformKey, 'platformKey', 'Unbekannt');
  }
  return '$downloadPrefix-$version-$suffix.$extension';
}

/// Nimmt die Version wieder aus dem Namen heraus — dieselbe Regel wie
/// `strip_version` in `tool/_common.sh`.
String latestDownloadName(String versionedName, String version) =>
    versionedName.replaceFirst('-$version-', '-');
