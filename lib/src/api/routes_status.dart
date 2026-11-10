import 'dart:io';

import 'package:shelf/shelf.dart';

import '../config/model.dart';
import '../version.dart';
import 'auth.dart';
import 'context.dart';
import 'faehigkeiten.dart';
import 'responses.dart';

/// Wie viele der letzten Fehler `GET /v1/status` mitliefert.
const int statusErrorLimit = 20;

/// Fähigkeit in `features`: die Bluetooth-Brücke ist da.
const String featureBluetooth = 'bluetooth';

/// Fähigkeit in `features`: der HTTPS-Zugang lauscht (Port in `httpsPort`).
const String featureHttps = 'https';

/// Fähigkeit in `features`: es gibt `/v1/update`. Ob der Ein-Klick auf
/// diesem System geht, sagt dort `oneClick`.
const String featureUpdate = 'update';

/// Was dieser Agent kann (`features` im Status).
///
/// Daran erkennt die Kasse, ob sie einen Weg anbieten darf – nicht an der
/// Versionsnummer: ein Connect ohne Hilfsprogramm (Windows, Linux) hat
/// dieselbe Version und trotzdem kein Bluetooth. `https` steht nur da,
/// solange der Zugang wirklich lauscht. Die Fähigkeiten ab 1.5.0 nur, wenn
/// der Agent sie angeschlossen hat ([AgentContext.faehigkeiten]) und ihre
/// Neuerung in [config] nicht abgeschaltet ist.
List<String> agentFeatures(AgentContext ctx, [AgentConfig? config]) => <String>[
  if (ctx.bluetooth?.available ?? false) featureBluetooth,
  if (ctx.httpsPort != null) featureHttps,
  if (ctx.updater != null) featureUpdate,
  for (final f in Faehigkeit.values)
    if (ctx.faehigkeiten.contains(f) && (config == null || f.aktivIn(config)))
      f.wireName,
];

/// `GET /v1/status` — Lebenszeichen des Agenten.
///
/// Ohne Token die Kurzform: Version, Betriebssystem, beide Ports (`port` für
/// HTTP, `httpsPort` für HTTPS, `null`, wenn der Zugang nicht lauscht), ob
/// schon gekoppelt ist, wie lange der Agent läuft und was er kann
/// (`features`). Damit findet die Kasse den Agenten über die Portreihe, ohne
/// etwas über die Geräte zu verraten.
/// Mit gültigem Token zusätzlich Systemversion und Prozessor (`osVersion`,
/// `arch`), Drucker, die letzten Fehler, mit HTTPS der
/// Zertifikatsstand (`tls`: Ablauf, ob vertraut) und – mit Brücke – der
/// Bluetooth-Zustand samt zugelassenen Geräten. Der startet Bluetooth nie,
/// wartet auf keinen Neustart und stößt auch keinen an: die Kasse fragt den
/// Status bei jedem Laden.
Future<Response> handleStatus(AgentContext ctx, Request request) async {
  final config = configOf(request);
  final body = <String, Object?>{
    'version': agentVersion,
    'os': Platform.operatingSystem,
    'port': ctx.port,
    'httpsPort': ctx.httpsPort,
    'paired': config.tokenHashes.isNotEmpty,
    'uptimeSeconds': ctx.uptimeSeconds,
    'features': agentFeatures(ctx, config),
    // Auch ohne Token: die Kasse muss vor dem Koppeln wissen, mit welchem
    // Connect sie spricht (zwei Benutzer am Rechner = zwei Connect). Die
    // Kennung verrät nichts über Geräte.
    if ((ctx.installationId ?? config.installationId) case final id?)
      'installationId': id,
  };

  if (isAuthenticated(request)) {
    final errors = ctx.log.recentErrors;
    final recent = errors.length > statusErrorLimit
        ? errors.sublist(errors.length - statusErrorLimit)
        : errors;
    body['printers'] = await ctx.printers();
    body['lastErrors'] = recent.map((entry) => entry.toJson()).toList();
    final system = await ctx.systemInfo?.call();
    if (system != null) {
      body['osVersion'] = system.osVersion;
      body['arch'] = system.arch;
    }
    final tls = await ctx.tls?.call();
    if (tls != null) body['tls'] = tls;
    final bluetooth = ctx.bluetooth;
    if (bluetooth != null) body['bluetooth'] = await bluetooth.summary();
    final terminal = ctx.terminalZustand?.call(config.terminal);
    if (terminal != null) body['terminal'] = terminal;
  }

  return okJson(body);
}
