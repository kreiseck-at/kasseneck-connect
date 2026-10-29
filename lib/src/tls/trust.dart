import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../process_runner.dart';
import 'certificates.dart';

/// Das Programm, über das Connect den Schlüsselbund fragt und ändert.
const String securityTool = '/usr/bin/security';

/// So lange darf die Frage nach Kennwort oder Touch ID offen bleiben. Danach
/// wird der Aufruf beendet ([runWithTimeout]), damit ein Installer nie
/// endlos hängt.
const Duration trustPromptTimeout = Duration(minutes: 3);

/// So lange darf eine Abfrage ohne Frage an den Benutzer dauern; danach wird
/// sie ebenso beendet.
const Duration trustQueryTimeout = Duration(seconds: 10);

/// Anmelde-Schlüsselbund des Benutzers mit dem Heimatordner [home].
String loginKeychainPath(String home) =>
    p.join(home, 'Library', 'Keychains', 'login.keychain-db');

/// Ob macOS der lokalen Zertifizierungsstelle [caCertPath] für HTTPS vertraut.
///
/// Gefragt wird das System selbst (`security verify-cert`), nicht die Liste
/// der Vertrauenseinstellungen: so zählt genau dieses Zertifikat — eine
/// gleichnamige ältere Stelle im Schlüsselbund macht es nicht „vertraut“ —
/// und auch „Nie vertrauen“ oder ein Eintrag im Admin-Bereich kommen richtig
/// heraus. Geprüft wird die Kette des Serverzertifikats ([serverCertPath],
/// ohne Angabe `server-cert.pem` daneben) mit der SSL-Richtlinie, so wie
/// Safari sie sieht: eine Stelle allein fällt dort immer durch, weil macOS am
/// Blatt die Erweiterung serverAuth verlangt. `-L` hält die Prüfung lokal.
///
/// Fehlt `security`, scheitert es oder antwortet es nicht binnen [timeout]
/// (dann wird es beendet), gilt die Stelle als nicht vertraut.
Future<bool> isLocalCaTrusted(
  String caCertPath, {
  required ProcessStarter start,
  String? serverCertPath,
  Duration timeout = trustQueryTimeout,
}) async {
  final server =
      serverCertPath ?? p.join(p.dirname(caCertPath), 'server-cert.pem');
  final result = await runWithTimeout(start, securityTool, <String>[
    'verify-cert',
    '-c',
    server,
    '-c',
    caCertPath,
    '-p',
    'ssl',
    '-L',
    '-q',
  ], timeout);
  return result?.exitCode == 0;
}

/// Vertraut der lokalen Zertifizierungsstelle [caCertPath] für SSL im
/// Anmelde-Schlüsselbund unter [home]:
/// `security add-trusted-cert -r trustRoot -p ssl -k <login.keychain-db> <ca>`.
/// macOS fragt dabei nach Kennwort oder Touch ID (Absender „security“).
///
/// Vorher verliert jede ältere Stelle von Connect ihr Vertrauen: eine neu
/// erzeugte Stelle heißt wie die alte, und vertraut sein soll immer höchstens
/// eine. Als Stelle von Connect zählt dabei nur, was es nachweislich ist
/// ([matchesLocalCa]): die Suche nach dem Namen trifft jede Bezeichnung, die
/// ihn nur enthält, und ein fremdes Zertifikat (auch eines mit „Nie
/// vertrauen“) bleibt unberührt. Lässt sich das Vertrauen nicht entziehen
/// (Frage abgebrochen), wird auch die neue Stelle nicht eingetragen. Ist die
/// aktuelle Stelle schon vertraut, fragt macOS nicht noch einmal — der
/// Installer ruft das bei jedem Update auf.
///
/// `true`, wenn die Stelle danach vertraut ist bzw. das Eintragen gelang.
/// Antwortet der Benutzer nicht binnen [promptTimeout], wird die Frage
/// beendet (`false`). Nie von selbst aus dem Agenten heraus aufrufen: eine
/// Frage aus dem Hintergrund bei der Anmeldung wäre ein Schreck ohne
/// Zusammenhang.
Future<bool> trustLocalCa(
  String caCertPath, {
  required ProcessStarter start,
  required String home,
  String? serverCertPath,
  String openssl = '/usr/bin/openssl',
  Duration promptTimeout = trustPromptTimeout,
  Duration queryTimeout = trustQueryTimeout,
}) async {
  final String pem;
  try {
    pem = await File(caCertPath).readAsString();
  } on FileSystemException {
    return false;
  }
  final current = _fingerprints(pem);
  if (current == null) return false;
  final keychain = loginKeychainPath(home);

  final others = (await _certificatesNamed(
    start,
    keychain,
    queryTimeout,
  )).where((certificate) => certificate.sha256 != current.sha256).toList();
  if (others.isNotEmpty) {
    final trusted = await _trustedHashes(start, queryTimeout);
    for (final other in others) {
      if (!trusted.contains(other.sha1)) continue;
      final removed = await _withPemFile(other.pem, (path) async {
        if (!await _isLocalCa(path, start, openssl, queryTimeout)) return true;
        return untrustLocalCa(path, start: start, timeout: promptTimeout);
      });
      if (!removed) return false;
    }
  }

  if (await isLocalCaTrusted(
    caCertPath,
    start: start,
    serverCertPath: serverCertPath,
    timeout: queryTimeout,
  )) {
    return true;
  }

  final result = await runWithTimeout(start, securityTool, <String>[
    'add-trusted-cert',
    '-r',
    'trustRoot',
    '-p',
    'ssl',
    '-k',
    keychain,
    caCertPath,
  ], promptTimeout);
  return result?.exitCode == 0;
}

/// Entzieht dem Zertifikat [caCertPath] das Vertrauen im Benutzerbereich:
/// `security remove-trusted-cert <ca>`. Auch das fragt macOS nach Kennwort
/// oder Touch ID; ohne Antwort binnen [timeout] wird die Frage beendet.
/// `true`, wenn es gelang.
Future<bool> untrustLocalCa(
  String caCertPath, {
  required ProcessStarter start,
  Duration timeout = trustPromptTimeout,
}) async {
  final result = await runWithTimeout(start, securityTool, <String>[
    'remove-trusted-cert',
    caCertPath,
  ], timeout);
  return result?.exitCode == 0;
}

/// Ob die Ausgabe von `openssl x509 -noout -text` eine Stelle von Connect
/// beschreibt: Inhaber **und** Aussteller genau `CN=Kasseneck Connect
/// (lokal)` (selbst ausgestellt), `CA:TRUE` und genau unsere
/// Namensbeschränkung (erlaubt nur `IP:127.0.0.1/255.255.255.255` und
/// `DNS:localhost`, nichts ausgeschlossen).
///
/// Gelesen wird `-text`, weil LibreSSL 3.3 (`/usr/bin/openssl` am Mac) kein
/// `-ext` kennt; diese Zeilen schreiben LibreSSL und OpenSSL 3 gleich.
bool matchesLocalCa(String x509Text) {
  final lines = x509Text
      .split('\n')
      .map((line) => line.trim())
      .toList(growable: false);
  const name = 'CN=$localCaName';
  if (!lines.contains('Subject: $name') || !lines.contains('Issuer: $name')) {
    return false;
  }

  final basic = lines.indexWhere(
    (line) => line.startsWith('X509v3 Basic Constraints:'),
  );
  if (basic < 0 ||
      basic + 1 >= lines.length ||
      !RegExp(r'^CA:TRUE\b').hasMatch(lines[basic + 1])) {
    return false;
  }

  final constraints = lines.indexWhere(
    (line) => line.startsWith('X509v3 Name Constraints:'),
  );
  if (constraints < 0) return false;
  final permitted = <String>{};
  String? section;
  for (final line in lines.skip(constraints + 1)) {
    if (line == 'Permitted:' || line == 'Excluded:') {
      section = line;
      if (section == 'Excluded:') return false;
      continue;
    }
    // Einträge wie `IP:…`, `DNS:…`, `email:…`; die nächste Erweiterung
    // (`X509v3 …:`) beendet den Block.
    if (section != null && RegExp(r'^[A-Za-z ]+:\S').hasMatch(line)) {
      permitted.add(line);
      continue;
    }
    break;
  }
  return permitted.length == 2 &&
      permitted.contains('IP:127.0.0.1/255.255.255.255') &&
      permitted.contains('DNS:localhost');
}

/// Ob das Zertifikat in [path] nachweislich eine Stelle von Connect ist.
/// Lässt es sich nicht lesen (kein openssl, unlesbar), zählt es nicht dazu.
Future<bool> _isLocalCa(
  String path,
  ProcessStarter start,
  String openssl,
  Duration timeout,
) async {
  final result = await runWithTimeout(start, openssl, <String>[
    'x509',
    '-noout',
    '-text',
    '-in',
    path,
  ], timeout);
  return result != null &&
      result.exitCode == 0 &&
      matchesLocalCa('${result.stdout}');
}

/// Ein Zertifikat aus dem Schlüsselbund mit seinen Fingerabdrücken
/// (Großbuchstaben-Hex, wie `security` sie schreibt).
class _KeychainCertificate {
  const _KeychainCertificate(this.sha256, this.sha1, this.pem);

  final String sha256;
  final String sha1;
  final String pem;
}

/// Alle Zertifikate im [keychain], deren Bezeichnung den Namen der lokalen
/// Stelle **enthält** (`-c` sucht nach Teilen) — nur Kandidaten, geprüft
/// wird erst mit [matchesLocalCa].
///
/// `find-certificate -a -Z -p` schreibt je Treffer `SHA-256 hash: …`,
/// `SHA-1 hash: …` und das PEM. Kein Treffer endet mit Exitcode 44 — dann,
/// wie bei jedem Fehler, eine leere Liste.
Future<List<_KeychainCertificate>> _certificatesNamed(
  ProcessStarter start,
  String keychain,
  Duration timeout,
) async {
  final result = await runWithTimeout(start, securityTool, <String>[
    'find-certificate',
    '-a',
    '-Z',
    '-p',
    '-c',
    localCaName,
    keychain,
  ], timeout);
  if (result == null || result.exitCode != 0) {
    return const <_KeychainCertificate>[];
  }
  final found = <_KeychainCertificate>[];
  String? sha256;
  String? sha1;
  for (final match in _findCertificateEntry.allMatches('${result.stdout}')) {
    if (match[1] != null) {
      sha256 = match[1]!.toUpperCase();
      sha1 = null;
    } else if (match[2] != null) {
      sha1 = match[2]!.toUpperCase();
    } else if (sha256 != null && sha1 != null) {
      found.add(_KeychainCertificate(sha256, sha1, '${match[3]!}\n'));
      sha256 = null;
      sha1 = null;
    }
  }
  return found;
}

final RegExp _findCertificateEntry = RegExp(
  r'^SHA-256 hash: ([0-9A-Fa-f]{64})\s*$|^SHA-1 hash: ([0-9A-Fa-f]{40})\s*$|'
  r'(-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----)',
  multiLine: true,
);

/// SHA-1 aller Zertifikate mit Vertrauenseinstellungen im Benutzerbereich.
///
/// `trust-settings-export` schreibt eine Plist, deren `trustList` die
/// Zertifikate nach SHA-1 führt. `dump-trust-settings` nennte nur Namen — und
/// die sind bei einer neu erzeugten Stelle gleich. Ohne Einstellungen endet
/// der Export mit einem Fehler: dann ist eben nichts vertraut.
Future<Set<String>> _trustedHashes(
  ProcessStarter start,
  Duration timeout,
) async {
  final work = await Directory.systemTemp.createTemp(
    'kasseneck-connect-trust-',
  );
  try {
    final export = p.join(work.path, 'vertrauen.plist');
    final result = await runWithTimeout(start, securityTool, <String>[
      'trust-settings-export',
      export,
    ], timeout);
    final file = File(export);
    if (result == null || result.exitCode != 0 || !file.existsSync()) {
      return const <String>{};
    }
    return RegExp(r'<key>([0-9A-Fa-f]{40})</key>')
        .allMatches(await file.readAsString())
        .map((match) => match[1]!.toUpperCase())
        .toSet();
  } finally {
    await _deleteQuietly(work);
  }
}

/// Legt [pem] für die Dauer von [action] als Datei ab — `security` und
/// `openssl` wollen eine Datei.
Future<bool> _withPemFile(
  String pem,
  Future<bool> Function(String path) action,
) async {
  final work = await Directory.systemTemp.createTemp(
    'kasseneck-connect-trust-',
  );
  try {
    final file = File(p.join(work.path, 'stelle.pem'));
    await file.writeAsString(pem, flush: true);
    return await action(file.path);
  } finally {
    await _deleteQuietly(work);
  }
}

/// SHA-256 und SHA-1 über das DER eines PEM-Zertifikats — dieselben Werte,
/// die `security` zeigt. `null`, wenn kein Zertifikat darin steht.
({String sha256, String sha1})? _fingerprints(String pem) {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) return null;
  final List<int> der;
  try {
    der = base64.decode(match[1]!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    return null;
  }
  if (der.isEmpty) return null;
  return (
    sha256: sha256.convert(der).toString().toUpperCase(),
    sha1: sha1.convert(der).toString().toUpperCase(),
  );
}

Future<void> _deleteQuietly(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // Ein Rest im System-Temp darf das Ergebnis nicht kippen.
  }
}
