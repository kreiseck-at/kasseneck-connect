import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'context.dart';
import 'cors.dart';
import 'responses.dart';
import 'routes_pair.dart';
import 'routes_status.dart';

/// Baut die Anfragekette des Agenten: CORS → Token → Router.
///
/// Die Reihenfolge ist bindend: eine fremde Herkunft fliegt raus, bevor
/// irgendetwas den Token prüft oder eine Route läuft.
///
/// [extraRoutes] hängt spätere Endpunkte an (Drucker, Terminal, `/v1/events`),
/// ohne diese Datei zu ändern.
Handler buildHandler(
  AgentContext ctx, {
  List<RouteRegistrar> extraRoutes = const <RouteRegistrar>[],
}) {
  final router = Router(
    notFoundHandler: (Request request) =>
        failJson(errorNotFound, 'Diesen Pfad gibt es nicht.', status: 404),
  );

  router.get('/v1/status', (Request request) => handleStatus(ctx, request));
  router.post('/v1/pair', (Request request) => handlePair(ctx, request));
  router.delete('/v1/pair', (Request request) => handleUnpair(ctx, request));

  for (final register in extraRoutes) {
    register(router, ctx);
  }

  return const Pipeline()
      .addMiddleware(corsMiddleware())
      .addMiddleware(tokenAuth(ctx.store))
      .addHandler(router.call);
}
