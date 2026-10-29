import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent.dart';
import 'api/routes_status.dart';
import 'autostart/autostart.dart';
import 'bluetooth/helper.dart';
import 'config/model.dart';
import 'config/paths.dart';
import 'config/store.dart';
import 'log/logger.dart';
import 'printers/registry.dart';
import 'process_runner.dart';
import 'tls/certificates.dart';
import 'tls/trust.dart';
import 'version.dart';

/// Fragt `GET /v1/status` an einem Port ab; `null` heißt „dort antwortet
/// niemand". In Tests austauschbar.
typedef StatusProbe = Future<Map<String, Object?>?> Function(int port);

/// Liefert die Drucker samt Zustand — in Tests austauschbar.
typedef PrinterStates = Future<List<Map<String, Object?>>> Function();

/// Wie lange die Diagnose je Port auf eine Antwort wartet.
const Duration doctorProbeTimeout = Duration(seconds: 1);

/// Wie viele der letzten Fehlerzeilen die Diagnose zeigt.
const int doctorErrorLimit = 10;

/// Zustand eines Ports der Portreihe.
class DoctorPort {
  const DoctorPort({required this.port, required this.status});

  final int port;

  /// Die Kurzform von `GET /v1/status`, oder `null` wenn nichts antwortet.
  final Map<String, Object?>? status;

  bool get reachable => status != null;

  String? get version => status?['version'] as String?;

  bool get paired => status?['paired'] == true;

  int? get uptimeSeconds => status?['uptimeSeconds'] as int?;

  /// Was der Agent kann (`features`); ältere Agenten melden nichts.
  List<String> get features => readStringList(status?['features']);

  /// Port des HTTPS-Zugangs; `null`, wenn er nicht lauscht (oder der Agent
  /// älter ist).
  int? get httpsPort => readInt(status?['httpsPort']);
}

/// Stand der Zertifikate für HTTPS, so wie die Diagnose ihn nachsieht.
class DoctorTls {
  const DoctorTls({
    required this.certificateExists,
    required this.notAfter,
    required this.trusted,
  });

  /// `server-cert.pem` liegt im Datenordner.
  final bool certificateExists;

  /// Ablauf des Serverzertifikats; `null`, wenn es fehlt oder unlesbar ist.
  final DateTime? notAfter;

  /// Ob macOS der lokalen Zertifizierungsstelle vertraut.
  final bool trusted;
}

/// Alles, was die Diagnose zusammengetragen hat.
class DoctorReport {
  const DoctorReport({
    required this.version,
    required this.operatingSystem,
    required this.executable,
    required this.configFile,
    required this.logFile,
    required this.configExists,
    required this.tokenCount,
    required this.ports,
    required this.printers,
    required this.autostartInstalled,
    required this.autostartTarget,
    required this.lastErrors,
    this.bluetoothHelper,
    this.tls,
  });

  final String version;
  final String operatingSystem;

  /// Die laufende Binary (`Platform.resolvedExecutable`).
  final String executable;

  final String configFile;
  final String logFile;
  final bool configExists;

  /// Anzahl gekoppelter Kassen (Token-Hashes).
  final int tokenCount;

  /// Die durchprobierte Portreihe.
  final List<DoctorPort> ports;

  /// Drucker mit Zustand, so wie `GET /v1/printers` sie liefert.
  final List<Map<String, Object?>> printers;

  final bool autostartInstalled;
  final String autostartTarget;

  /// Die letzten Fehlerzeilen aus der Logdatei.
  final List<String> lastErrors;

  /// Pfad zum Bluetooth-Hilfsprogramm; `null`, wenn es fehlt (außerhalb von
  /// macOS immer).
  final String? bluetoothHelper;

  /// Zertifikate für HTTPS; `null` außerhalb von macOS (dort gibt es den
  /// Zugang noch nicht).
  final DoctorTls? tls;

  bool get paired => tokenCount > 0;

  /// Der Port, an dem tatsächlich ein Agent antwortet.
  DoctorPort? get runningOn {
    for (final port in ports) {
      if (port.reachable) return port;
    }
    return null;
  }
}

/// Trägt den Zustand des Rechners zusammen.
///
/// Die Diagnose läuft als **eigener Prozess** neben dem Agenten und hat keinen
/// Kopplungstoken. Sie sieht deshalb nur die Kurzform von `GET /v1/status`,
/// liest die Fehler aus der Logdatei statt aus dem Ringpuffer des laufenden
/// Agenten und fragt die Drucker selbst ab, statt den Agenten zu fragen.
///
/// Bluetooth fasst sie dagegen nie selbst an: das Hilfsprogramm wird nur im
/// Dateisystem gesucht ([findBluetoothHelper]), nie gestartet – sonst fragte
/// macOS im Namen des Terminals nach der Bluetooth-Freigabe. Ob der Agent
/// Bluetooth anbietet, steht in seinem Status (`features`).
///
/// Die Zertifikate für HTTPS sieht sie am Mac nur nach: Ablauf über
/// `openssl`, Vertrauen über `security verify-cert` — sie legt keine an und
/// trägt kein Vertrauen ein ([runProcess] ersetzt beides im Test).
/// [environment] ersetzt in Tests die Umgebung des Prozesses.
Future<DoctorReport> collectDoctorReport({
  required ConfigPaths paths,
  StatusProbe? probe,
  PrinterStates? printerStates,
  Autostart? autostart,
  String? operatingSystem,
  String? executable,
  Map<String, String>? environment,
  ProcessRunner? runProcess,
}) async {
  final store = ConfigStore(paths);
  final config = await store.load();

  final resolvedProbe = probe ?? probeAgentStatus;
  final ports = <DoctorPort>[];
  for (var offset = 0; offset < portFallbackRange; offset++) {
    final port = defaultAgentPort + offset;
    ports.add(DoctorPort(port: port, status: await resolvedProbe(port)));
  }

  final resolvedAutostart =
      autostart ??
      autostartForPlatform(paths: paths, operatingSystem: operatingSystem);

  final states =
      printerStates ??
      () => PrinterRegistry(
        store: store,
        log: AgentLog(paths.logDirectory, minimumLevel: LogLevel.error),
      ).summaries(probe: true);

  final os = operatingSystem ?? Platform.operatingSystem;
  final tls = os == 'macos'
      ? await _inspectTls(paths, runProcess ?? Process.run)
      : null;

  return DoctorReport(
    version: agentVersion,
    operatingSystem: os,
    executable: executable ?? Platform.resolvedExecutable,
    configFile: paths.configFile.path,
    logFile: AgentLog.fileIn(paths.logDirectory).path,
    configExists: paths.configFile.existsSync(),
    tokenCount: config.tokenHashes.length,
    ports: ports,
    printers: await states(),
    autostartInstalled: await resolvedAutostart.isInstalled(),
    autostartTarget: resolvedAutostart.target,
    lastErrors: readRecentErrors(paths.logDirectory),
    bluetoothHelper: findBluetoothHelper(
      environment: environment,
      operatingSystem: operatingSystem,
      executable: executable,
    ),
    tls: tls,
  );
}

/// Liest Ablauf und Vertrauen der vorhandenen Zertifikate, ohne etwas
/// anzulegen. Ohne Zertifikat wird gar nichts aufgerufen.
Future<DoctorTls> _inspectTls(ConfigPaths paths, ProcessRunner run) async {
  final certificates = LocalCertificates(
    directory: paths.directory,
    run: run,
    log: AgentLog(paths.logDirectory, minimumLevel: LogLevel.error),
  );
  final exists = certificates.serverCertFile.existsSync();
  final notAfter = exists ? await certificates.readServerNotAfter() : null;
  final trusted =
      exists &&
      certificates.caCertFile.existsSync() &&
      await isLocalCaTrusted(
        certificates.caCertFile.path,
        run: run,
        serverCertPath: certificates.serverCertFile.path,
      );
  return DoctorTls(
    certificateExists: exists,
    notAfter: notAfter,
    trusted: trusted,
  );
}

/// Fragt `GET /v1/status` auf `127.0.0.1:<port>` ab.
///
/// Ohne `Origin`-Kopfzeile — genau dafür ist der Status als einzige Route
/// ohne Herkunft erreichbar.
Future<Map<String, Object?>?> probeAgentStatus(int port) async {
  final client = HttpClient()..connectionTimeout = doctorProbeTimeout;
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/v1/status'),
    );
    final response = await request.close().timeout(doctorProbeTimeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(doctorProbeTimeout);
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return null;
    return decoded['ok'] == true ? decoded : null;
  } on Object {
    // Kein Agent, falsche Antwort, Zeitüberschreitung — alles dasselbe:
    // an diesem Port läuft nichts, was uns gehört.
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Liest die letzten Fehlerzeilen aus `connect.log`.
List<String> readRecentErrors(
  Directory logDirectory, {
  int limit = doctorErrorLimit,
}) {
  final file = AgentLog.fileIn(logDirectory);
  if (!file.existsSync()) return const <String>[];
  final List<String> lines;
  try {
    lines = file.readAsLinesSync();
  } on FileSystemException {
    return const <String>[];
  }
  final errors = lines
      .where((line) => line.contains('  ERROR  '))
      .toList(growable: false);
  return errors.length <= limit
      ? errors
      : errors.sublist(errors.length - limit);
}

/// Formatiert den Bericht für die Konsole.
String formatDoctorReport(DoctorReport report) {
  final buffer = StringBuffer()
    ..writeln('$agentName ${report.version} (${report.operatingSystem})')
    ..writeln()
    ..writeln('Installation')
    ..writeln('  Programm       ${report.executable}')
    ..writeln(
      '  Konfiguration  ${report.configFile}'
      '${report.configExists ? '' : '  (noch nicht angelegt)'}',
    )
    ..writeln('  Log            ${report.logFile}')
    ..writeln(
      '  Kopplung       ${report.paired ? 'ja (${report.tokenCount} Kasse'
                '${report.tokenCount == 1 ? '' : 'n'})' : 'nein — `kasseneck-connect pair` starten'}',
    )
    ..writeln()
    ..writeln('Lokale API (127.0.0.1)');

  final running = report.runningOn;
  if (running == null) {
    buffer.writeln(
      '  Kein Agent erreichbar auf ${report.ports.first.port}–'
      '${report.ports.last.port} — läuft er? `kasseneck-connect run`',
    );
  } else {
    for (final port in report.ports) {
      if (!port.reachable) continue;
      buffer.writeln(
        '  Port ${port.port}     antwortet — Version ${port.version ?? '?'}, '
        '${port.paired ? 'gekoppelt' : 'nicht gekoppelt'}, '
        'läuft seit ${port.uptimeSeconds ?? 0} s',
      );
    }
  }
  _writeHttps(buffer, report, running);

  buffer
    ..writeln()
    ..writeln('Drucker');
  if (report.printers.isEmpty) {
    buffer.writeln('  keine eingetragen');
  } else {
    for (final printer in report.printers) {
      buffer.writeln(
        '  ${printer['name']}  (${printer['kind']} '
        '${printer['host']}:${printer['port']})  — ${printer['state']}',
      );
    }
  }

  buffer
    ..writeln()
    ..writeln('Bluetooth');
  final helper = report.bluetoothHelper;
  if (helper != null) {
    buffer.writeln('  Bluetooth-Hilfsprogramm: vorhanden ($helper)');
  } else if (report.operatingSystem == 'macos') {
    buffer.writeln(
      '  Bluetooth-Hilfsprogramm: fehlt — Kasseneck Connect neu installieren',
    );
  } else {
    buffer.writeln(
      '  Bluetooth-Hilfsprogramm: fehlt (Bluetooth gibt es bisher nur am Mac)',
    );
  }
  if (running != null) {
    buffer.writeln(
      running.features.contains(featureBluetooth)
          ? '  Agent: mit Bluetooth'
          : '  Agent: ohne Bluetooth',
    );
  }

  buffer
    ..writeln()
    ..writeln('Autostart')
    ..writeln(
      report.autostartInstalled
          ? '  eingerichtet: ${report.autostartTarget}'
          : '  nicht eingerichtet — `kasseneck-connect install-autostart`',
    )
    ..writeln()
    ..writeln('Letzte Fehler');
  if (report.lastErrors.isEmpty) {
    buffer.writeln('  keine');
  } else {
    for (final error in report.lastErrors) {
      buffer.writeln('  $error');
    }
  }

  return buffer.toString();
}

/// Die Zeile „HTTPS: Port …, Zertifikat gültig bis …, vertraut ja/nein“.
void _writeHttps(
  StringBuffer buffer,
  DoctorReport report,
  DoctorPort? running,
) {
  final tls = report.tls;
  if (tls == null) {
    buffer.writeln('  HTTPS: gibt es bisher nur am Mac');
    return;
  }
  final httpsPort = running?.httpsPort;
  final notAfter = tls.notAfter;
  final port = httpsPort == null ? 'aus' : 'Port $httpsPort';
  final certificate = !tls.certificateExists
      ? 'kein Zertifikat'
      : notAfter == null
      ? 'Zertifikat unlesbar'
      : 'Zertifikat gültig bis ${notAfter.toUtc().toIso8601String().substring(0, 10)}';
  buffer.writeln(
    '  HTTPS: $port, $certificate, vertraut ${tls.trusted ? 'ja' : 'nein'}',
  );
  if (!tls.trusted) {
    buffer.writeln(
      '  Ohne Vertrauen erreicht Safari Connect nicht: '
      '`kasseneck-connect zertifikat-vertrauen`',
    );
  }
}
