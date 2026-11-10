import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'agent.dart';
import 'autostart/autostart.dart';
import 'betrieb/betrieb_lock.dart';
import 'config/paths.dart';
import 'config/store.dart';
import 'doctor.dart';
import 'log/launchd_logs.dart';
import 'log/logger.dart';
import 'pairing/pairing.dart';
import 'process_runner.dart';
import 'tls/certificates.dart';
import 'tls/trust.dart';
import 'version.dart';

/// Exit-Code für falsche Verwendung (unbekannter Befehl, fehlende Option).
const int exitCodeUsage = 64;

/// Exit-Code, wenn der Agent nicht starten konnte.
const int exitCodeFailed = 70;

/// Befehle der Kommandozeile.
const List<String> agentCommands = <String>[
  'run',
  'pair',
  'install-autostart',
  'uninstall-autostart',
  'zertifikat-vertrauen',
  'betrieb-abwarten',
  'doctor',
  'version',
];

/// Baut den Argument-Parser des Agenten.
ArgParser buildArgParser() {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Diese Hilfe anzeigen.',
    )
    ..addFlag('version', negatable: false, help: 'Version ausgeben.');
  for (final command in agentCommands) {
    parser.addCommand(command, ArgParser());
  }
  return parser;
}

/// Führt die Kommandozeile aus und liefert den Exit-Code.
///
/// Alle benannten Parameter außer [out]/[err] sind **Nahtstellen für Tests**:
/// Datenverzeichnis, Ersatz für das Warten auf SIGINT/SIGTERM, Wunschport,
/// Browser, Autostart-Weg, die beiden Abfragen der Diagnose, Betriebssystem,
/// Umgebung (`HOME`) und der Programmstart für `openssl`/`security` (Runner,
/// dazu der Starter für Aufrufe mit Zeitgrenze). Ohne sie
/// entscheidet das laufende System — kein Test startet ein echtes
/// `launchctl`, keiner fragt echte Drucker oder den echten Schlüsselbund.
Future<int> runCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  ConfigPaths? paths,
  Future<void> Function()? awaitShutdown,
  int? preferredPort,
  bool? openBrowser,
  Autostart? autostart,
  StatusProbe? statusProbe,
  PrinterStates? printerStates,
  String? operatingSystem,
  Map<String, String>? environment,
  ProcessRunner? runProcess,
  ProcessStarter? startProcess,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = buildArgParser();

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderrSink.writeln(e.message);
    _writeUsage(stderrSink, parser);
    return exitCodeUsage;
  }

  if (results.flag('help')) {
    _writeUsage(stdoutSink, parser);
    return 0;
  }
  if (results.flag('version')) {
    stdoutSink.writeln('$agentName $agentVersion');
    return 0;
  }

  final command = results.command?.name;
  if (command == null) {
    if (results.rest.isNotEmpty) {
      stderrSink.writeln('Unbekannter Befehl: ${results.rest.first}');
    }
    _writeUsage(stderrSink, parser);
    return exitCodeUsage;
  }

  final resolvedPaths = paths ?? ConfigPaths.forPlatform();
  final os = operatingSystem ?? Platform.operatingSystem;
  final run = runProcess ?? Process.run;
  // Aufrufe, die hängen können, laufen mit Zeitgrenze über einen Starter.
  // Reicht ein Test nur einen Runner herein, laufen sie über ihn.
  final start =
      startProcess ??
      (runProcess == null ? Process.start : processStarterFrom(runProcess));

  switch (command) {
    case 'version':
      stdoutSink.writeln('$agentName $agentVersion');
      return 0;
    case 'run':
      return _runAgent(
        resolvedPaths,
        stdoutSink,
        stderrSink,
        awaitShutdown: awaitShutdown,
        preferredPort: preferredPort,
        openBrowser: openBrowser,
        https: os == 'macos',
        runProcess: run,
        startProcess: start,
        neustartMoeglich: () => _neustartMoeglich(
          os,
          autostart ?? autostartForPlatform(paths: resolvedPaths),
        ),
      );
    case 'betrieb-abwarten':
      final gewartet = await warteAufFreienBetrieb(
        betriebLockDatei(resolvedPaths.directory),
      );
      if (gewartet > Duration.zero) {
        stdoutSink.writeln(
          'Ein Druck oder eine Zahlung lief – ${gewartet.inSeconds} s gewartet.',
        );
      }
      return 0;
    case 'pair':
      return _printPairingCode(resolvedPaths, stdoutSink);
    case 'install-autostart':
      return _changeAutostart(
        resolvedPaths,
        stdoutSink,
        stderrSink,
        autostart: autostart,
        install: true,
      );
    case 'uninstall-autostart':
      return _changeAutostart(
        resolvedPaths,
        stdoutSink,
        stderrSink,
        autostart: autostart,
        install: false,
      );
    case 'zertifikat-vertrauen':
      return _trustLocalCertificate(
        resolvedPaths,
        stdoutSink,
        stderrSink,
        operatingSystem: os,
        environment: environment ?? Platform.environment,
        runProcess: run,
        startProcess: start,
      );
    case 'doctor':
      return _printDoctorReport(
        resolvedPaths,
        stdoutSink,
        autostart: autostart,
        statusProbe: statusProbe,
        printerStates: printerStates,
        operatingSystem: operatingSystem,
        runProcess: run,
        startProcess: start,
      );
  }

  // Hierher kommt nur, wer einen Befehl in [agentCommands] einträgt und das
  // Verdrahten vergisst — der Parser kennt keine anderen Namen.
  throw StateError('Befehl „$command“ ist nicht verdrahtet.');
}

/// `install-autostart` / `uninstall-autostart`.
Future<int> _changeAutostart(
  ConfigPaths paths,
  StringSink out,
  StringSink err, {
  required bool install,
  Autostart? autostart,
}) async {
  final target = autostart ?? autostartForPlatform(paths: paths);
  final result = install ? await target.install() : await target.uninstall();

  if (result.ok) {
    out.writeln(result.message);
    return 0;
  }
  err.writeln(result.message);
  if (result.detail != null) err.writeln(result.detail);
  return exitCodeFailed;
}

/// `zertifikat-vertrauen` — der lokalen Zertifizierungsstelle einmal im
/// Anmelde-Schlüsselbund vertrauen, damit Safari den HTTPS-Zugang annimmt.
///
/// Läuft bei der Installation (postinstall, als angemeldeter Benutzer) und
/// von Hand. Fehlen die Zertifikate, entstehen sie hier — mit eigener
/// [LocalCertificates]-Instanz; die Sperrdatei ordnet das mit einem
/// gleichzeitig startenden Agenten. Ist die Stelle schon vertraut, fragt
/// macOS nicht noch einmal.
Future<int> _trustLocalCertificate(
  ConfigPaths paths,
  StringSink out,
  StringSink err, {
  required String operatingSystem,
  required Map<String, String> environment,
  required ProcessRunner runProcess,
  required ProcessStarter startProcess,
}) async {
  const retry = 'Erneut versuchen: kasseneck-connect zertifikat-vertrauen';
  if (operatingSystem != 'macos') {
    err.writeln('Den HTTPS-Zugang gibt es bisher nur am Mac.');
    return exitCodeFailed;
  }
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    err.writeln(
      'HOME ist nicht gesetzt — der Anmelde-Schlüsselbund lässt sich nicht '
      'finden.',
    );
    return exitCodeFailed;
  }

  final log = AgentLog(paths.logDirectory);
  final TlsFiles files;
  try {
    files = await LocalCertificates(
      directory: paths.directory,
      run: runProcess,
      log: log,
    ).ensure();
  } on Exception catch (e) {
    // openssl fehlt oder scheitert (TlsCertificateException), oder der
    // Datenordner ist nicht beschreibbar.
    log.error('Zertifikate für HTTPS ließen sich nicht anlegen', e);
    err
      ..writeln('Die Zertifikate für HTTPS ließen sich nicht anlegen: $e')
      ..writeln(retry);
    return exitCodeFailed;
  }

  final before = await isLocalCaTrusted(
    files.caCertPath,
    start: startProcess,
    serverCertPath: files.serverCertPath,
  );
  if (!before) {
    out.writeln(
      'macOS fragt gleich nach dem Kennwort oder Touch ID (Absender '
      '„security“), um der lokalen Zertifizierungsstelle „$localCaName“ zu '
      'vertrauen.',
    );
  }
  final trusted = await trustLocalCa(
    files.caCertPath,
    start: startProcess,
    home: home,
    serverCertPath: files.serverCertPath,
  );
  if (!trusted) {
    log.warn('HTTPS: Vertrauen in die lokale Zertifizierungsstelle fehlt.');
    err
      ..writeln(
        'Der lokalen Zertifizierungsstelle ließ sich nicht vertrauen — '
        'abgebrochen oder abgelehnt. Ohne Vertrauen erreicht Safari Connect '
        'nicht.',
      )
      ..writeln(retry);
    return exitCodeFailed;
  }
  log.info('HTTPS: der lokalen Zertifizierungsstelle wird vertraut.');
  out.writeln(
    before
        ? 'Der lokalen Zertifizierungsstelle wird bereits vertraut.'
        : 'Der lokalen Zertifizierungsstelle wird jetzt vertraut '
              '(Anmelde-Schlüsselbund).',
  );
  return 0;
}

/// `doctor` — Zustand des Rechners für den Support.
Future<int> _printDoctorReport(
  ConfigPaths paths,
  StringSink out, {
  Autostart? autostart,
  StatusProbe? statusProbe,
  PrinterStates? printerStates,
  String? operatingSystem,
  ProcessRunner? runProcess,
  ProcessStarter? startProcess,
}) async {
  final report = await collectDoctorReport(
    paths: paths,
    probe: statusProbe,
    printerStates: printerStates,
    autostart: autostart,
    operatingSystem: operatingSystem,
    runProcess: runProcess,
    startProcess: startProcess,
  );
  out.write(formatDoctorReport(report));
  return 0;
}

/// `run` — Agent starten und laufen lassen, bis SIGINT/SIGTERM kommt.
///
/// Der ganze Betrieb läuft in einer abgeschirmten Zone. Ein unbehandelter
/// asynchroner Fehler — ein verwaistes `Future`, ein stolpernder
/// Timer-Rückruf irgendwo im Druckstapel — würde den Prozess sonst mitreißen,
/// und auf einem Windows-Kassenrechner startet ihn niemand neu: die Aufgabe
/// der Aufgabenplanung greift erst bei der nächsten Anmeldung. Hier landet der
/// Fehler im Log, und der Agent nimmt weiter Anfragen an.
///
/// `Isolate.current.addErrorListener` hilft dabei ausdrücklich **nicht**: ein
/// Fehler aus der Wurzelzone beendet die Isolate auch mit Zuhörer, und zwar
/// bevor dieser gerufen wird — der Fehler stünde dann nicht einmal mehr auf
/// stderr. Die Zone ist der Schutz, nicht der Zuhörer.
/// Ob der Autostart einen beendeten Agenten wieder startet: macOS
/// (`KeepAlive`) und Linux (systemd `Restart=always`), und nur, wenn er
/// eingerichtet ist. Windows startet ihn erst bei der nächsten Anmeldung.
Future<bool> _neustartMoeglich(String os, Autostart autostart) async {
  if (os != 'macos' && os != 'linux') return false;
  try {
    return await autostart.isInstalled();
  } on Object {
    // Unklar: dann lieber kein Neustart auf Zuruf.
    return false;
  }
}

Future<int> _runAgent(
  ConfigPaths paths,
  StringSink out,
  StringSink err, {
  Future<void> Function()? awaitShutdown,
  int? preferredPort,
  bool? openBrowser,
  required bool https,
  required ProcessRunner runProcess,
  required ProcessStarter startProcess,
  required Future<bool> Function() neustartMoeglich,
}) {
  final log = AgentLog(paths.logDirectory);
  final done = Completer<int>();

  runZonedGuarded(
    () async {
      var code = exitCodeFailed;
      try {
        code = await _serveAgent(
          paths,
          log,
          out,
          err,
          awaitShutdown: awaitShutdown,
          preferredPort: preferredPort,
          openBrowser: openBrowser,
          https: https,
          runProcess: runProcess,
          startProcess: startProcess,
          neustartMoeglich: neustartMoeglich,
        );
      } on Object catch (e) {
        // Der Ablauf selbst ist gescheitert — das beendet den Befehl.
        log.error('Der Agent ist abgebrochen', e);
        err.writeln('Der Agent ist abgebrochen: $e');
      } finally {
        if (!done.isCompleted) done.complete(code);
      }
    },
    (error, stackTrace) {
      // Alles, was **neben** dem Ablauf schiefgeht: nur vermerken.
      log.error('Unbehandelter Fehler — der Agent läuft weiter', error);
      err.writeln('Unbehandelter Fehler (siehe Log): $error');
    },
  );

  return done.future;
}

/// Der eigentliche Ablauf von `run`, aufgerufen aus der abgeschirmten Zone.
Future<int> _serveAgent(
  ConfigPaths paths,
  AgentLog log,
  StringSink out,
  StringSink err, {
  Future<void> Function()? awaitShutdown,
  int? preferredPort,
  bool? openBrowser,
  required bool https,
  required ProcessRunner runProcess,
  required ProcessStarter startProcess,
  required Future<bool> Function() neustartMoeglich,
}) async {
  // launchd hängt Ausgabe und Fehler unbegrenzt an; beim Start kürzen.
  kuerzeLaunchdLogs(paths.logDirectory, log: log);
  // Mit Log: eine unbrauchbare config.json soll laut auffallen.
  final store = ConfigStore(paths, log: log);
  final neustartAngefordert = Completer<void>();
  final config = await store.load();
  final agent = Agent(
    store: store,
    log: log,
    preferredPort: preferredPort ?? config.port,
    // Ohne ausdrückliche Angabe entscheidet die Umgebung: im Testlauf und auf
    // Servern ist `KASSENECK_CONNECT_NO_BROWSER=1` gesetzt.
    openBrowser: openBrowser ?? (Platform.environment[noBrowserEnvVar] != '1'),
    // HTTPS bisher nur am Mac (Windows und Linux mit ihrer Bluetooth-Etappe).
    https: https,
    preferredHttpsPort: config.httpsPort,
    runProcess: runProcess,
    startProcess: startProcess,
    // Neustart auf Zuruf: der Agent hält an, der Prozess endet, der
    // Autostart startet ihn neu.
    neustart: await neustartMoeglich()
        ? () async {
            if (!neustartAngefordert.isCompleted) {
              neustartAngefordert.complete();
            }
          }
        : null,
  );

  try {
    await agent.start();
  } on Object catch (e) {
    log.error('Start fehlgeschlagen', e);
    err.writeln('Start fehlgeschlagen: $e');
    return exitCodeFailed;
  }

  out.writeln('Lokale API: http://127.0.0.1:${agent.port}');
  final httpsPort = agent.httpsPort;
  if (httpsPort != null) {
    out.writeln('Lokale API über HTTPS: https://127.0.0.1:$httpsPort');
  }
  final pending = (await store.load()).pairing.code;
  if (pending != null) {
    out.writeln('Kopplungscode: $pending (10 Minuten gültig)');
  }

  await Future.any(<Future<void>>[
    (awaitShutdown ?? _awaitShutdownSignal)(),
    neustartAngefordert.future,
  ]);
  if (neustartAngefordert.isCompleted) {
    log.info('Connect beendet sich für den Neustart.');
  }
  await agent.stop();
  return 0;
}

/// `pair` — neuen Code erzeugen und anzeigen.
///
/// Läuft in einem eigenen Prozess neben dem Agenten: der Code steht in der
/// `config.json`, und der laufende Agent liest ihn dort bei `POST /v1/pair`.
Future<int> _printPairingCode(ConfigPaths paths, StringSink out) async {
  final log = AgentLog(paths.logDirectory);
  final store = ConfigStore(paths, log: log);
  final code = await Pairing(store: store, log: log).newCode();
  final config = await store.load();

  out
    ..writeln('Kopplungscode: $code')
    ..writeln('Gültig 10 Minuten. In der Kasse eingeben oder aufrufen:')
    ..writeln(pairingPageUrl(code, config.port));
  return 0;
}

/// Wartet auf das Abschaltsignal des Betriebssystems.
Future<void> _awaitShutdownSignal() {
  final completer = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];

  void shutdown(ProcessSignal signal) {
    if (!completer.isCompleted) completer.complete();
  }

  subscriptions.add(ProcessSignal.sigint.watch().listen(shutdown));
  if (!Platform.isWindows) {
    subscriptions.add(ProcessSignal.sigterm.watch().listen(shutdown));
  }

  return completer.future.whenComplete(() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });
}

void _writeUsage(StringSink sink, ArgParser parser) {
  sink
    ..writeln('$agentName $agentVersion — lokaler Agent der Kasseneck-Kasse')
    ..writeln()
    ..writeln('Verwendung: $agentName <befehl> [optionen]')
    ..writeln()
    ..writeln('Befehle:')
    ..writeln(
      '  run                  Agent starten (lokale API auf 127.0.0.1).',
    )
    ..writeln('  pair                 Kopplungscode für die Kasse anzeigen.')
    ..writeln('  install-autostart    Autostart einrichten.')
    ..writeln('  uninstall-autostart  Autostart entfernen.')
    ..writeln(
      '  zertifikat-vertrauen Der lokalen Zertifizierungsstelle für HTTPS '
      'vertrauen (Mac).',
    )
    ..writeln(
      '  betrieb-abwarten     Warten, bis kein Druck und keine Zahlung läuft '
      '(höchstens 5 min).',
    )
    ..writeln('  doctor               Diagnose ausgeben.')
    ..writeln('  version              Version ausgeben.')
    ..writeln()
    ..writeln('Optionen:')
    ..writeln(parser.usage);
}
