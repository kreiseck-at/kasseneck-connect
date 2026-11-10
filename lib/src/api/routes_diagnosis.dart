import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../diagnose.dart';
import '../version.dart';
import 'auth.dart';
import 'context.dart';
import 'responses.dart';
import 'routes_status.dart';

/// `GET /v1/diagnosis?lines=200` (Token) – alles, was der Support zur
/// Fehlersuche braucht, nach Positivliste (`diagnose.dart`).
RouteRegistrar diagnosisRoutes() {
  return (Router router, AgentContext ctx) {
    router.get(
      '/v1/diagnosis',
      (Request request) => handleDiagnosis(ctx, request),
    );
  };
}

Future<Response> handleDiagnosis(AgentContext ctx, Request request) async {
  final config = configOf(request);
  final zeilen = diagnoseZeilen(request.requestedUri.queryParameters['lines']);
  final system = await ctx.systemInfo?.call();
  final fehler = ctx.log.recentErrors;
  final letzte = fehler.length > statusErrorLimit
      ? fehler.sublist(fehler.length - statusErrorLimit)
      : fehler;
  return okJson(<String, Object?>{
    'version': agentVersion,
    'os': Platform.operatingSystem,
    'osVersion': system?.osVersion,
    'arch': system?.arch,
    'installationId': ctx.installationId ?? config.installationId,
    'uptimeSeconds': ctx.uptimeSeconds,
    'port': ctx.port,
    'httpsPort': ctx.httpsPort,
    'features': agentFeatures(ctx, config),
    'config': konfigurationFuerDiagnose(config),
    'printers': await ctx.printers(),
    'terminal': ctx.terminalZustand?.call(config.terminal),
    'operations': ctx.vorgaenge?.anzahl ?? 0,
    'lastErrors': <Map<String, Object?>>[
      for (final eintrag in letzte)
        <String, Object?>{
          ...eintrag.toJson(),
          'message': schwaerze(eintrag.message),
        },
    ],
    'log': <String>[
      for (final zeile in letzteLogzeilen(ctx.log.directory, zeilen))
        schwaerze(zeile),
    ],
    'update': ctx.updater?.stand(),
    'relocations': <Map<String, Object?>>[
      for (final w in config.relocations) w.toJson(),
    ],
  });
}
