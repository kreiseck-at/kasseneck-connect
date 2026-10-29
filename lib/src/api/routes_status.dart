import 'dart:io';

import 'package:shelf/shelf.dart';

import '../version.dart';
import 'auth.dart';
import 'context.dart';
import 'responses.dart';

/// Wie viele der letzten Fehler `GET /v1/status` mitliefert.
const int statusErrorLimit = 20;

/// Fähigkeit in `features`: die Bluetooth-Brücke ist da.
const String featureBluetooth = 'bluetooth';

/// Fähigkeit in `features`: der HTTPS-Zugang lauscht (Port in `httpsPort`).
const String featureHttps = 'https';

/// Was dieser Agent kann (`features` im Status).
///
/// Daran erkennt die Kasse, ob sie einen Weg anbieten darf – nicht an der
/// Versionsnummer: ein Connect ohne Hilfsprogramm (Windows, Linux) hat
/// dieselbe Version und trotzdem kein Bluetooth. `https` steht nur da,
/// solange der Zugang wirklich lauscht.
List<String> agentFeatures(AgentContext ctx) => <String>[
  if (ctx.bluetooth?.available ?? false) featureBluetooth,
  if (ctx.httpsPort != null) featureHttps,
];

/// `GET /v1/status` — Lebenszeichen des Agenten.
///
/// Ohne Token die Kurzform: Version, Betriebssystem, beide Ports (`port` für
/// HTTP, `httpsPort` für HTTPS, `null`, wenn der Zugang nicht lauscht), ob
/// schon gekoppelt ist, wie lange der Agent läuft und was er kann
/// (`features`). Damit findet die Kasse den Agenten über die Portreihe, ohne
/// etwas über die Geräte zu verraten.
/// Mit gültigem Token zusätzlich Drucker, die letzten Fehler, mit HTTPS der
/// Zertifikatsstand (`tls`: Ablauf, ob vertraut) und – mit Brücke – der
/// Bluetooth-Zustand samt zugelassenen Geräten. Der startet Bluetooth nie:
/// die Kasse fragt den Status bei jedem Laden.
Future<Response> handleStatus(AgentContext ctx, Request request) async {
  final config = configOf(request);
  final body = <String, Object?>{
    'version': agentVersion,
    'os': Platform.operatingSystem,
    'port': ctx.port,
    'httpsPort': ctx.httpsPort,
    'paired': config.tokenHashes.isNotEmpty,
    'uptimeSeconds': ctx.uptimeSeconds,
    'features': agentFeatures(ctx),
  };

  if (isAuthenticated(request)) {
    final errors = ctx.log.recentErrors;
    final recent = errors.length > statusErrorLimit
        ? errors.sublist(errors.length - statusErrorLimit)
        : errors;
    body['printers'] = await ctx.printers();
    body['lastErrors'] = recent.map((entry) => entry.toJson()).toList();
    final tls = await ctx.tls?.call();
    if (tls != null) body['tls'] = tls;
    final bluetooth = ctx.bluetooth;
    if (bluetooth != null) body['bluetooth'] = await bluetooth.summary();
  }

  return okJson(body);
}
