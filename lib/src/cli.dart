import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'agent.dart';
import 'config/paths.dart';
import 'config/store.dart';
import 'log/logger.dart';
import 'pairing/pairing.dart';
import 'version.dart';

/// Exit-Code für Befehle, die es noch nicht gibt.
const int exitCodeNotImplemented = 2;

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
/// [paths], [awaitShutdown], [preferredPort] und [openBrowser] sind Nahtstellen
/// für Tests: Datenverzeichnis, Ersatz für das Warten auf SIGINT/SIGTERM,
/// Wunschport und das Öffnen des Browsers.
Future<int> runCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  ConfigPaths? paths,
  Future<void> Function()? awaitShutdown,
  int? preferredPort,
  bool? openBrowser,
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
      );
    case 'pair':
      return _printPairingCode(resolvedPaths, stdoutSink);
    default:
      stderrSink.writeln('Befehl „$command“: noch nicht verfügbar.');
      return exitCodeNotImplemented;
  }
}

/// `run` — Agent starten und laufen lassen, bis SIGINT/SIGTERM kommt.
Future<int> _runAgent(
  ConfigPaths paths,
  StringSink out,
  StringSink err, {
  Future<void> Function()? awaitShutdown,
  int? preferredPort,
  bool? openBrowser,
}) async {
  final store = ConfigStore(paths);
  final log = AgentLog(paths.logDirectory);
  final config = await store.load();
  final agent = Agent(
    store: store,
    log: log,
    preferredPort: preferredPort ?? config.port,
    // Ohne ausdrückliche Angabe entscheidet die Umgebung: im Testlauf und auf
    // Servern ist `KASSENECK_CONNECT_NO_BROWSER=1` gesetzt.
    openBrowser: openBrowser ?? (Platform.environment[noBrowserEnvVar] != '1'),
  );

  try {
    await agent.start();
  } on Object catch (e) {
    log.error('Start fehlgeschlagen', e);
    err.writeln('Start fehlgeschlagen: $e');
    return exitCodeFailed;
  }

  out.writeln('Lokale API: http://127.0.0.1:${agent.port}');
  final pending = (await store.load()).pairing.code;
  if (pending != null) {
    out.writeln('Kopplungscode: $pending (10 Minuten gültig)');
  }

  await (awaitShutdown ?? _awaitShutdownSignal)();
  await agent.stop();
  return 0;
}

/// `pair` — neuen Code erzeugen und anzeigen.
///
/// Läuft in einem eigenen Prozess neben dem Agenten: der Code steht in der
/// `config.json`, und der laufende Agent liest ihn dort bei `POST /v1/pair`.
Future<int> _printPairingCode(ConfigPaths paths, StringSink out) async {
  final store = ConfigStore(paths);
  final log = AgentLog(paths.logDirectory);
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
    ..writeln('  doctor               Diagnose ausgeben.')
    ..writeln('  version              Version ausgeben.')
    ..writeln()
    ..writeln('Optionen:')
    ..writeln(parser.usage);
}
