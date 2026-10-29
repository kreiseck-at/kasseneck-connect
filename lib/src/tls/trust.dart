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
/// gibt der Befehl auf, damit ein Installer nie endlos hängt — bestätigt der
/// Benutzer später doch noch, gilt das Vertrauen trotzdem.
const Duration trustPromptTimeout = Duration(minutes: 3);

/// So lange darf eine Abfrage ohne Frage an den Benutzer dauern.
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
/// Fehlt `security`, hängt es oder scheitert es, gilt die Stelle als nicht
/// vertraut.
Future<bool> isLocalCaTrusted(
  String caCertPath, {
  required ProcessRunner run,
  String? serverCertPath,
  Duration timeout = trustQueryTimeout,
}) async {
  final server =
      serverCertPath ?? p.join(p.dirname(caCertPath), 'server-cert.pem');
  final result = await _security(run, <String>[
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
/// Vorher verliert jede andere Stelle gleichen Namens im Anmelde-Schlüsselbund
/// ihr Vertrauen: eine neu erzeugte Stelle heißt wie die alte, und vertraut
/// sein soll immer höchstens eine. Lässt sich das nicht entziehen (Frage
/// abgebrochen), wird auch die neue Stelle nicht eingetragen. Ist die
/// aktuelle Stelle schon vertraut, fragt macOS nicht noch einmal — der
/// Installer ruft das bei jedem Update auf.
///
/// `true`, wenn die Stelle danach vertraut ist bzw. das Eintragen gelang.
/// Nie von selbst aus dem Agenten heraus aufrufen: eine Frage aus dem
/// Hintergrund bei der Anmeldung wäre ein Schreck ohne Zusammenhang.
Future<bool> trustLocalCa(
  String caCertPath, {
  required ProcessRunner run,
  required String home,
  String? serverCertPath,
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
    run,
    keychain,
    queryTimeout,
  )).where((certificate) => certificate.sha256 != current.sha256).toList();
  if (others.isNotEmpty) {
    final trusted = await _trustedHashes(run, queryTimeout);
    for (final other in others) {
      if (!trusted.contains(other.sha1)) continue;
      if (!await _untrustPem(other.pem, run, promptTimeout)) return false;
    }
  }

  if (await isLocalCaTrusted(
    caCertPath,
    run: run,
    serverCertPath: serverCertPath,
    timeout: queryTimeout,
  )) {
    return true;
  }

  final result = await _security(run, <String>[
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
/// oder Touch ID. `true`, wenn es gelang.
Future<bool> untrustLocalCa(
  String caCertPath, {
  required ProcessRunner run,
  Duration timeout = trustPromptTimeout,
}) async {
  final result = await _security(run, <String>[
    'remove-trusted-cert',
    caCertPath,
  ], timeout);
  return result?.exitCode == 0;
}

/// Ein Zertifikat aus dem Schlüsselbund mit seinen Fingerabdrücken
/// (Großbuchstaben-Hex, wie `security` sie schreibt).
class _KeychainCertificate {
  const _KeychainCertificate(this.sha256, this.sha1, this.pem);

  final String sha256;
  final String sha1;
  final String pem;
}

/// Alle Zertifikate mit dem Namen der lokalen Stelle im [keychain].
///
/// `find-certificate -a -Z -p` schreibt je Treffer `SHA-256 hash: …`,
/// `SHA-1 hash: …` und das PEM. Kein Treffer endet mit Exitcode 44 — dann,
/// wie bei jedem Fehler, eine leere Liste.
Future<List<_KeychainCertificate>> _certificatesNamed(
  ProcessRunner run,
  String keychain,
  Duration timeout,
) async {
  final result = await _security(run, <String>[
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
Future<Set<String>> _trustedHashes(ProcessRunner run, Duration timeout) async {
  final work = await Directory.systemTemp.createTemp(
    'kasseneck-connect-trust-',
  );
  try {
    final export = p.join(work.path, 'vertrauen.plist');
    final result = await _security(run, <String>[
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

/// Entzieht einem Zertifikat aus dem Schlüsselbund das Vertrauen; dafür muss
/// es als Datei vorliegen.
Future<bool> _untrustPem(
  String pem,
  ProcessRunner run,
  Duration timeout,
) async {
  final work = await Directory.systemTemp.createTemp(
    'kasseneck-connect-trust-',
  );
  try {
    final file = File(p.join(work.path, 'alte-stelle.pem'));
    await file.writeAsString(pem, flush: true);
    return await untrustLocalCa(file.path, run: run, timeout: timeout);
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

/// Ruft `security` auf; `null`, wenn es fehlt oder nicht rechtzeitig
/// antwortet.
Future<ProcessResult?> _security(
  ProcessRunner run,
  List<String> arguments,
  Duration timeout,
) async {
  try {
    return await run(securityTool, arguments).timeout(timeout);
  } on ProcessException {
    return null;
  } on TimeoutException {
    return null;
  }
}

Future<void> _deleteQuietly(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // Ein Rest im System-Temp darf das Ergebnis nicht kippen.
  }
}
