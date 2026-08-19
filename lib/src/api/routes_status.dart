import 'dart:io';

import 'package:shelf/shelf.dart';

import '../version.dart';
import 'auth.dart';
import 'context.dart';
import 'responses.dart';

/// Wie viele der letzten Fehler `GET /v1/status` mitliefert.
const int statusErrorLimit = 20;

/// `GET /v1/status` — Lebenszeichen des Agenten.
///
/// Ohne Token die Kurzform: Version, Betriebssystem, Port, ob schon gekoppelt
/// ist und wie lange der Agent läuft. Damit findet die Kasse den Agenten über
/// die Portreihe, ohne etwas über die Geräte zu verraten.
/// Mit gültigem Token zusätzlich Drucker und die letzten Fehler.
Future<Response> handleStatus(AgentContext ctx, Request request) async {
  final config = configOf(request);
  final body = <String, Object?>{
    'version': agentVersion,
    'os': Platform.operatingSystem,
    'port': ctx.port,
    'paired': config.tokenHashes.isNotEmpty,
    'uptimeSeconds': ctx.uptimeSeconds,
  };

  if (isAuthenticated(request)) {
    final errors = ctx.log.recentErrors;
    final recent = errors.length > statusErrorLimit
        ? errors.sublist(errors.length - statusErrorLimit)
        : errors;
    body['printers'] = await ctx.printers();
    body['lastErrors'] = recent.map((entry) => entry.toJson()).toList();
  }

  return okJson(body);
}
