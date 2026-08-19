import 'dart:io';

import 'package:args/args.dart';

import 'version.dart';

/// Exit-Code für Befehle, die es noch nicht gibt.
const int exitCodeNotImplemented = 2;

/// Exit-Code für falsche Verwendung (unbekannter Befehl, fehlende Option).
const int exitCodeUsage = 64;

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
/// Bis auf `version` sind die Befehle in dieser Etappe noch nicht gebaut; sie
/// melden das ausdrücklich und enden mit [exitCodeNotImplemented].
int runCli(List<String> arguments, {StringSink? out, StringSink? err}) {
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

  if (command == 'version') {
    stdoutSink.writeln('$agentName $agentVersion');
    return 0;
  }

  stderrSink.writeln('Befehl „$command“: noch nicht verfügbar.');
  return exitCodeNotImplemented;
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
