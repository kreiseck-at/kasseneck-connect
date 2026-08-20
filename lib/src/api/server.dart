import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'context.dart';
import 'cors.dart';
import 'responses.dart';
import 'routes_pair.dart';
import 'routes_status.dart';

/// Baut die Anfragekette des Agenten: Konfiguration → CORS → Token → Router.
///
/// Die Reihenfolge ist bindend: die Konfiguration wird einmal gelesen (beide
/// Prüfungen und die Routen sehen dieselbe Momentaufnahme), dann fliegt eine
/// fremde Herkunft raus, bevor irgendetwas den Token prüft oder eine Route
/// läuft.
///
/// [extraRoutes] hängt spätere Endpunkte an (Drucker, Terminal, `/v1/events`),
/// ohne diese Datei zu ändern.
Handler buildHandler(
  AgentContext ctx, {
  List<RouteRegistrar> extraRoutes = const <RouteRegistrar>[],
  Map<String, String>? environment,
}) {
  final router = Router(
    notFoundHandler: (Request request) =>
        failJson(errorNotFound, 'Diesen Pfad gibt es nicht.', status: 404),
  );

  router.get('/v1/status', (Request request) => handleStatus(ctx, request));
  router.post('/v1/pair', (Request request) => handlePair(ctx, request));
  router.post(
    '/v1/pair/request',
    (Request request) => handlePairRequest(ctx, request),
  );
  router.post(
    '/v1/pair/direct',
    (Request request) => handlePairDirect(ctx, request),
  );
  router.delete('/v1/pair', (Request request) => handleUnpair(ctx, request));

  for (final register in extraRoutes) {
    register(router, ctx);
  }

  return const Pipeline()
      .addMiddleware(configLoader(ctx.store))
      .addMiddleware(corsMiddleware(environment: environment))
      .addMiddleware(tokenAuth())
      .addHandler(router.call);
}
