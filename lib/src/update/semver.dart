/// Versionsvergleich nach SemVer – nur die Form `MAJOR.MINOR.PATCH`.
///
/// Connect veröffentlicht nur solche Versionen (`pubspec.yaml`, Tag
/// `v<version>`, `latest.json`). Alles andere ist ein Fehler und kein
/// „irgendwie älter“: eine Aktualisierung entscheidet nie auf Grund einer
/// Zeichenkette, die sie nicht versteht.
library;

final RegExp _semver = RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$');

/// Vergleicht [a] mit [b]: negativ, wenn [a] älter ist, `0` bei Gleichheit,
/// positiv, wenn [a] neuer ist. Wirft [FormatException] bei anderer Form.
int compareVersions(String a, String b) {
  final left = _parts(a);
  final right = _parts(b);
  for (var i = 0; i < 3; i++) {
    final diff = left[i].compareTo(right[i]);
    if (diff != 0) return diff;
  }
  return 0;
}

/// Ob [candidate] echt neuer ist als [current].
bool isNewer(String candidate, String current) =>
    compareVersions(candidate, current) > 0;

List<int> _parts(String version) {
  final match = _semver.firstMatch(version);
  if (match == null) {
    throw FormatException('Keine Version der Form MAJOR.MINOR.PATCH', version);
  }
  return <int>[
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}
