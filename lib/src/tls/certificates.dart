import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../log/logger.dart';
import '../process_runner.dart';

/// Name (CN) der lokalen Zertifizierungsstelle — so steht sie im
/// Schlüsselbund.
const String localCaName = 'Kasseneck Connect (lokal)';

/// Laufzeit der Zertifizierungsstelle: zehn Jahre, damit der Benutzer ihr nur
/// einmal vertrauen muss.
const int localCaDays = 3650;

/// Laufzeit des Serverzertifikats. 397 Tage bleiben unter der 398-Tage-Grenze,
/// die Apple und die Browser für Serverzertifikate ziehen.
const int serverCertDays = 397;

/// So lange vor Ablauf wird ein Zertifikat erneuert.
const Duration renewalWindow = Duration(days: 30);

/// Erweiterungsdatei für `openssl req` und `openssl x509 -req`.
///
/// Bewusst nur, was LibreSSL 3.3 (`/usr/bin/openssl` auf jedem Mac) und
/// OpenSSL 3 gleich verstehen: kein `-addext`, und vor allem kein
/// `prompt = no` — LibreSSL nähme dann den Namen aus der Datei statt aus
/// `-subj`, und das Serverzertifikat hieße wie die Stelle. Schlüsselkennungen
/// (SKI/AKI) stehen ausdrücklich da: OpenSSL 3 setzt sie von selbst, LibreSSL
/// nicht, und ohne sie fände macOS nach einer neuen Stelle womöglich die alte
/// gleichnamige im Schlüsselbund.
const String _extensionConfig = '''
[req]
distinguished_name = req_dn

[req_dn]

[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
nameConstraints = critical, permitted;IP:127.0.0.1/255.255.255.255, permitted;DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always

[v3_server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1, DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
''';

final Random _random = Random.secure();

/// Die Dateien für den HTTPS-Zugang, wie [LocalCertificates.ensure] sie
/// hinterlässt.
class TlsFiles {
  const TlsFiles({
    required this.caCertPath,
    required this.serverCertPath,
    required this.serverKeyPath,
    required this.serverNotAfter,
    required this.caCreated,
  });

  /// Zertifikat der lokalen Zertifizierungsstelle (das, dem vertraut wird).
  final String caCertPath;

  /// Serverzertifikat für `127.0.0.1` und `localhost`.
  final String serverCertPath;

  /// Schlüssel des Serverzertifikats (Modus 0600).
  final String serverKeyPath;

  /// Ablauf des Serverzertifikats (UTC).
  final DateTime serverNotAfter;

  /// Die Zertifizierungsstelle ist in diesem Lauf neu entstanden — ihr muss
  /// neu vertraut werden.
  final bool caCreated;

  @override
  String toString() =>
      'TlsFiles(server bis ${serverNotAfter.toIso8601String()}, '
      'caCreated: $caCreated)';
}

/// Zertifikate ließen sich nicht anlegen (kein `openssl`, Aufruf gescheitert,
/// Rechte nicht setzbar). Der Bestand auf der Platte bleibt dann unverändert.
class TlsCertificateException implements Exception {
  const TlsCertificateException(this.message, {this.detail});

  /// Klartext für Log und Diagnose.
  final String message;

  /// Erste Fehlerzeile des gescheiterten Programms, falls vorhanden.
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// Lokale Zertifizierungsstelle und Serverzertifikat für den HTTPS-Zugang.
///
/// Safari lässt eine Seite unter `https://` nicht an `http://127.0.0.1`
/// (gemischter Inhalt). Connect bekommt darum eine eigene Stelle je Rechner,
/// per Namensbeschränkung nur für `127.0.0.1` und `localhost` gültig — ein
/// abhandengekommener Schlüssel taugt so für keine fremde Adresse. Der
/// Benutzer vertraut ihr einmal; das Serverzertifikat daraus erneuert Connect
/// selbst, ohne neue Frage.
///
/// Ablage unter `<directory>/tls/`: `ca-cert.pem`, `ca-key.pem`,
/// `server-cert.pem`, `server-key.pem`; Schlüssel mit Modus 0600, der Ordner
/// mit 0700. Erzeugt wird über die `openssl`-Befehlszeile (macOS:
/// `/usr/bin/openssl`, LibreSSL), jeder Aufruf geht über den [ProcessRunner].
///
/// Geschrieben wird nur über Temp-Dateien im selben Ordner und `rename`. Ein
/// Zertifikat steht dabei nie neben einem fremden Schlüssel: Beim Festschreiben
/// fällt zuerst das alte Zertifikat weg, dann kommt der Schlüssel, zuletzt das
/// Zertifikat. Bricht der Ablauf irgendwo ab, fehlt höchstens ein Zertifikat —
/// und der nächste Lauf stellt es neu aus.
class LocalCertificates {
  LocalCertificates({
    required Directory directory,
    required ProcessRunner run,
    required AgentLog log,
    String openssl = '/usr/bin/openssl',
    DateTime Function()? clock,
  }) : tlsDirectory = Directory(p.join(directory.path, 'tls')),
       _run = run,
       _log = log,
       _openssl = openssl,
       _clock = clock ?? DateTime.now;

  /// Ablageordner `<directory>/tls`.
  final Directory tlsDirectory;

  final ProcessRunner _run;
  final AgentLog _log;
  final String _openssl;
  final DateTime Function() _clock;

  /// Serialisiert die Läufe dieses Prozesses; die Sperrdatei tut dasselbe
  /// über Prozesse hinweg.
  Future<void> _queue = Future<void>.value();

  File get caCertFile => File(p.join(tlsDirectory.path, 'ca-cert.pem'));

  File get caKeyFile => File(p.join(tlsDirectory.path, 'ca-key.pem'));

  File get serverCertFile => File(p.join(tlsDirectory.path, 'server-cert.pem'));

  File get serverKeyFile => File(p.join(tlsDirectory.path, 'server-key.pem'));

  File get _lockFile => File(p.join(tlsDirectory.path, 'tls.lock'));

  /// Ob ein Zertifikat mit Ablauf [notAfter] erneuert werden muss: wenn es in
  /// weniger als 30 Tagen abläuft (oder schon abgelaufen ist).
  bool renewalDue(DateTime notAfter) =>
      notAfter.isBefore(_clock().add(renewalWindow));

  /// Ablauf des vorhandenen Serverzertifikats, ohne zu sperren, zu prüfen
  /// oder etwas anzulegen — für die Diagnose, die nur nachsieht. `null`, wenn
  /// es fehlt oder sich nicht lesen lässt (auch ohne `openssl`).
  Future<DateTime?> readServerNotAfter() async {
    if (!serverCertFile.existsSync()) return null;
    try {
      return (await _readCertificate(serverCertFile))?.notAfter;
    } on TlsCertificateException {
      return null;
    }
  }

  /// Sorgt für gültige Zertifikate und liefert ihre Pfade.
  ///
  /// Fehlt die Zertifizierungsstelle, ist sie unlesbar, passt ihr Schlüssel
  /// nicht oder läuft sie in weniger als 30 Tagen ab, entstehen Stelle und
  /// Serverzertifikat neu (`caCreated: true`). Sonst wird nur ein fehlendes,
  /// ungültiges, nicht zur Stelle passendes oder bald ablaufendes
  /// Serverzertifikat neu ausgestellt. Ist alles gültig, ändert sich nichts.
  ///
  /// Wirft [TlsCertificateException], wenn `openssl` fehlt oder scheitert;
  /// der Bestand bleibt dann, wie er war.
  ///
  /// Mehrere Aufrufe — auch aus zwei Prozessen, etwa `run` und
  /// `zertifikat-vertrauen` direkt nach der Installation — laufen
  /// nacheinander: sonst legten beide eine Stelle an, und vertraut würde
  /// womöglich die, die gleich darauf überschrieben ist.
  Future<TlsFiles> ensure() {
    final result = _queue.then((_) => _ensureExclusive());
    _queue = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<TlsFiles> _ensureExclusive() async {
    if (!tlsDirectory.existsSync()) {
      await tlsDirectory.create(recursive: true);
    }
    final lock = await _acquireLock();
    try {
      // Bei jedem Lauf, nicht nur beim Anlegen: Stirbt ein Lauf zwischen
      // Anlegen und chmod, oder ändert jemand die Rechte, stünde der Ordner
      // sonst für immer offen.
      await _restrict(tlsDirectory.path, '700');
      _removeLeftovers();
      for (final key in <File>[caKeyFile, serverKeyFile]) {
        if (key.existsSync()) await _restrict(key.path, '600');
      }

      final caProblem = await _caProblem();
      if (caProblem != null) {
        return await _issue(newCa: true, reason: caProblem);
      }
      final server = await _inspectServer();
      if (server.problem != null) {
        return await _issue(newCa: false, reason: server.problem!);
      }
      return TlsFiles(
        caCertPath: caCertFile.path,
        serverCertPath: serverCertFile.path,
        serverKeyPath: serverKeyFile.path,
        serverNotAfter: server.notAfter!,
        caCreated: false,
      );
    } finally {
      await _releaseLock(lock);
    }
  }

  /// Warum die Stelle neu muss, oder `null`, wenn sie taugt.
  Future<String?> _caProblem() async {
    if (!caCertFile.existsSync()) return 'fehlt';
    if (!caKeyFile.existsSync()) return 'Schlüssel fehlt';
    final cert = await _readCertificate(caCertFile);
    if (cert == null) return 'unlesbar';
    if (renewalDue(cert.notAfter)) {
      return 'läuft am ${_day(cert.notAfter)} ab';
    }
    final publicKey = await _readPublicKey(caKeyFile);
    if (publicKey != cert.publicKey) return 'Schlüssel passt nicht';
    return null;
  }

  /// Prüft das Serverzertifikat gegen die (gültige) Stelle.
  Future<({String? problem, DateTime? notAfter})> _inspectServer() async {
    if (!serverCertFile.existsSync()) return (problem: 'fehlt', notAfter: null);
    if (!serverKeyFile.existsSync()) {
      return (problem: 'Schlüssel fehlt', notAfter: null);
    }
    final cert = await _readCertificate(serverCertFile);
    if (cert == null) return (problem: 'unlesbar', notAfter: null);
    if (renewalDue(cert.notAfter)) {
      return (problem: 'läuft am ${_day(cert.notAfter)} ab', notAfter: null);
    }
    final publicKey = await _readPublicKey(serverKeyFile);
    if (publicKey != cert.publicKey) {
      return (problem: 'Schlüssel passt nicht', notAfter: null);
    }
    if (!await _chainsTo(caCertFile, serverCertFile)) {
      return (problem: 'passt nicht zur Zertifizierungsstelle', notAfter: null);
    }
    return (problem: null, notAfter: cert.notAfter);
  }

  /// Stellt das Serverzertifikat neu aus, mit [newCa] vorher auch die Stelle.
  Future<TlsFiles> _issue({required bool newCa, required String reason}) async {
    final work = await Directory.systemTemp.createTemp(
      'kasseneck-connect-tls-',
    );
    final temps = <File>[];
    File tempFor(File target) {
      final suffix = _random.nextInt(1 << 32).toRadixString(36);
      final temp = File('${target.path}.$pid.$suffix.tmp');
      temps.add(temp);
      return temp;
    }

    try {
      final config = File(p.join(work.path, 'openssl.cnf'));
      await config.writeAsString(_extensionConfig, flush: true);

      var caCert = caCertFile;
      var caKey = caKeyFile;
      if (newCa) {
        caKey = tempFor(caKeyFile);
        await _generateKey(caKey);
        caCert = tempFor(caCertFile);
        await _opensslOrFail(<String>[
          'req',
          '-new',
          '-x509',
          '-key',
          caKey.path,
          '-out',
          caCert.path,
          '-days',
          '$localCaDays',
          '-sha256',
          '-subj',
          '/CN=$localCaName',
          '-set_serial',
          _serial(),
          '-config',
          config.path,
          '-extensions',
          'v3_ca',
        ]);
      }

      final serverKey = tempFor(serverKeyFile);
      await _generateKey(serverKey);
      final request = File(p.join(work.path, 'server.csr'));
      // CN `localhost`: Browser lesen ihn nicht (es zählt der SAN), aber
      // Prüfer, die ihn doch als Namen nehmen, finden ihn innerhalb der
      // Namensbeschränkung.
      await _opensslOrFail(<String>[
        'req',
        '-new',
        '-key',
        serverKey.path,
        '-out',
        request.path,
        '-sha256',
        '-subj',
        '/CN=localhost',
        '-config',
        config.path,
      ]);
      final serverCert = tempFor(serverCertFile);
      await _opensslOrFail(<String>[
        'x509',
        '-req',
        '-in',
        request.path,
        '-CA',
        caCert.path,
        '-CAkey',
        caKey.path,
        '-set_serial',
        _serial(),
        '-days',
        '$serverCertDays',
        '-sha256',
        '-extfile',
        config.path,
        '-extensions',
        'v3_server',
        '-out',
        serverCert.path,
      ]);

      // Nur übernehmen, was sich lesen lässt und gegen die Stelle prüft.
      final issued = await _readCertificate(serverCert);
      if (issued == null) {
        throw const TlsCertificateException(
          'Das neue Serverzertifikat lässt sich nicht lesen.',
        );
      }
      if (!await _chainsTo(caCert, serverCert)) {
        throw const TlsCertificateException(
          'Das neue Serverzertifikat prüft nicht gegen die '
          'Zertifizierungsstelle.',
        );
      }

      // Festschreiben: altes Zertifikat weg, Schlüssel, dann Zertifikat.
      // Ein Serverzertifikat der alten Stelle darf die neue nicht überleben.
      _deleteIfExists(serverCertFile);
      if (newCa) {
        _deleteIfExists(caCertFile);
        await caKey.rename(caKeyFile.path);
        await caCert.rename(caCertFile.path);
        _log.info(
          'TLS: neue lokale Zertifizierungsstelle angelegt ($reason). '
          'Ihr muss neu vertraut werden.',
        );
      }
      await serverKey.rename(serverKeyFile.path);
      await serverCert.rename(serverCertFile.path);
      _log.info(
        'TLS: Serverzertifikat ausgestellt '
        '(${newCa ? 'neue Zertifizierungsstelle' : reason}), '
        'gültig bis ${_day(issued.notAfter)}.',
      );

      return TlsFiles(
        caCertPath: caCertFile.path,
        serverCertPath: serverCertFile.path,
        serverKeyPath: serverKeyFile.path,
        serverNotAfter: issued.notAfter,
        caCreated: newCa,
      );
    } finally {
      for (final temp in temps) {
        _deleteIfExists(temp);
      }
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // Ein Rest im System-Temp darf das Ergebnis nicht kippen.
      }
    }
  }

  /// EC-Schlüssel P-256 nach [target], ohne dass er je lesbar für andere
  /// dasteht: LibreSSL legt die Datei mit `-out` selbst mit 0644 an. Darum
  /// entsteht sie vorher leer und bekommt 0600 — in eine vorhandene Datei
  /// schreiben LibreSSL und OpenSSL 3, ohne ihre Rechte zu ändern.
  Future<void> _generateKey(File target) async {
    await target.writeAsBytes(const <int>[], flush: true);
    await _restrict(target.path, '600');
    await _opensslOrFail(<String>[
      'ecparam',
      '-name',
      'prime256v1',
      '-param_enc',
      'named_curve',
      '-genkey',
      '-noout',
      '-out',
      target.path,
    ]);
  }

  /// Ablauf und öffentlicher Schlüssel eines Zertifikats; `null`, wenn es
  /// sich nicht lesen lässt.
  Future<({DateTime notAfter, String publicKey})?> _readCertificate(
    File cert,
  ) async {
    final result = await _opensslCall(<String>[
      'x509',
      '-noout',
      '-enddate',
      '-pubkey',
      '-in',
      cert.path,
    ]);
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}';
    final notAfter = parseOpensslNotAfter(output);
    final publicKey = _publicKeyBlock(output);
    if (notAfter == null || publicKey == null) return null;
    return (notAfter: notAfter, publicKey: publicKey);
  }

  /// Öffentlicher Schlüssel zu einem privaten; `null`, wenn er sich nicht
  /// lesen lässt. Der private Schlüssel selbst kommt nie in Dart an.
  Future<String?> _readPublicKey(File key) async {
    final result = await _opensslCall(<String>[
      'pkey',
      '-in',
      key.path,
      '-pubout',
    ]);
    if (result.exitCode != 0) return null;
    return _publicKeyBlock('${result.stdout}');
  }

  /// Ob [serverCert] gegen [caCert] als Serverzertifikat prüft.
  Future<bool> _chainsTo(File caCert, File serverCert) async {
    final result = await _opensslCall(<String>[
      'verify',
      '-purpose',
      'sslserver',
      '-CAfile',
      caCert.path,
      serverCert.path,
    ]);
    // Ältere openssl-Fassungen enden auch bei Fehlern mit 0 — darum zählt
    // erst die Zeile „…: OK“.
    return result.exitCode == 0 && '${result.stdout}'.trim().endsWith(': OK');
  }

  Future<ProcessResult> _opensslCall(List<String> arguments) async {
    try {
      return await _run(_openssl, arguments);
    } on ProcessException catch (e) {
      throw TlsCertificateException(
        'openssl lässt sich nicht starten ($_openssl).',
        detail: e.message,
      );
    }
  }

  Future<void> _opensslOrFail(List<String> arguments) async {
    final result = await _opensslCall(arguments);
    if (result.exitCode != 0) {
      throw TlsCertificateException(
        'openssl ${arguments.first} ist gescheitert '
        '(Exitcode ${result.exitCode}).',
        detail: _firstErrorLine('${result.stderr}'),
      );
    }
  }

  /// Setzt Dateirechte; ohne sie bleibt kein Schlüssel liegen.
  Future<void> _restrict(String path, String mode) async {
    if (Platform.isWindows) return;
    ProcessResult result;
    try {
      result = await _run('chmod', <String>[mode, path]);
    } on ProcessException catch (e) {
      throw TlsCertificateException(
        'Die Rechte von ${p.basename(path)} lassen sich nicht setzen.',
        detail: e.message,
      );
    }
    if (result.exitCode != 0) {
      throw TlsCertificateException(
        'Die Rechte von ${p.basename(path)} lassen sich nicht setzen.',
        detail: _firstErrorLine('${result.stderr}'),
      );
    }
  }

  /// Temp-Dateien eines abgebrochenen Laufs (Absturz, Stromausfall). Unter
  /// der Sperre schreibt sonst niemand im Ordner.
  void _removeLeftovers() {
    for (final entity in tlsDirectory.listSync()) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        _deleteIfExists(entity);
      }
    }
  }

  static void _deleteIfExists(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Wer nicht löschen kann, scheitert spätestens beim Umbenennen laut.
    }
  }

  /// Prozessübergreifende Sperre; lässt sie sich nicht holen, läuft es
  /// ungesperrt weiter (wie bei der Konfiguration).
  Future<RandomAccessFile?> _acquireLock() async {
    RandomAccessFile? handle;
    try {
      handle = await _lockFile.open(mode: FileMode.write);
      await handle.lock(FileLock.blockingExclusive);
      return handle;
    } on FileSystemException {
      await handle?.close();
      return null;
    }
  }

  Future<void> _releaseLock(RandomAccessFile? handle) async {
    if (handle == null) return;
    try {
      await handle.unlock();
    } on FileSystemException {
      // Schon freigegeben.
    }
    try {
      await handle.close();
    } on FileSystemException {
      // Schon zu.
    }
  }
}

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

final RegExp _notAfterLine = RegExp(
  r'^notAfter=([A-Z][a-z]{2}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2})(?:\.\d+)? '
  r'(\d{4}) GMT\r?$',
  multiLine: true,
);

/// Liest `notAfter=Oct 28 23:09:07 2027 GMT` aus der Ausgabe von
/// `openssl x509 -enddate` (Tag mit Leerzeichen aufgefüllt, so schreiben es
/// LibreSSL und OpenSSL gleich). `null`, wenn keine solche Zeile dasteht.
DateTime? parseOpensslNotAfter(String output) {
  final match = _notAfterLine.firstMatch(output);
  if (match == null) return null;
  final month = _months.indexOf(match[1]!) + 1;
  if (month == 0) return null;
  return DateTime.utc(
    int.parse(match[6]!),
    month,
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
  );
}

/// Der PEM-Block des öffentlichen Schlüssels ohne Leerraum — zum Vergleichen.
String? _publicKeyBlock(String output) {
  final match = RegExp(
    r'-----BEGIN PUBLIC KEY-----[\s\S]*?-----END PUBLIC KEY-----',
  ).firstMatch(output);
  return match?.group(0)?.replaceAll(RegExp(r'\s'), '');
}

/// Zufällige Seriennummer (128 Bit) als `0x…`: positiv und ohne führende Null,
/// damit beide openssl-Fassungen sie gleich lesen. Ohne Seriennummer-Datei —
/// es bleibt nichts liegen.
String _serial() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[0] = (bytes[0] & 0x3f) | 0x40;
  return '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Erste aussagekräftige Fehlerzeile. LibreSSL setzt vor die eigentliche
/// Meldung Zeilen wie `8332…:error:02FFF002:…` mit Quellpfaden.
String? _firstErrorLine(String stderr) {
  final lines = stderr
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;
  final readable = lines.firstWhere(
    (line) => !RegExp(r'^[0-9a-fA-F]+:error:').hasMatch(line),
    orElse: () => lines.first,
  );
  return readable.length <= 200 ? readable : readable.substring(0, 200);
}

String _day(DateTime time) {
  final t = time.toUtc();
  final month = t.month.toString().padLeft(2, '0');
  final day = t.day.toString().padLeft(2, '0');
  return '${t.year}-$month-$day';
}
