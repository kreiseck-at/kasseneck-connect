import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../update/updater.dart';
import 'context.dart';
import 'responses.dart';

/// `GET /v1/update` und `POST /v1/update` – Aktualisieren auf einen Klick.
///
/// Beide nur mit Token und erlaubter Herkunft (wie alle Pfade außer Status
/// und Kopplung). Ohne Aktualisierer im Kontext gibt es die Pfade nicht
/// (`not_found`), und `features` nennt `update` nicht.
///
/// - `GET`: `{current, latest, available, platform, size, oneClick}`; wartet
///   höchstens kurz auf GitHub (siehe `UpdateFeed`).
/// - `POST`: startet und antwortet sofort mit `{started: true}`; der Rest
///   kommt als `update.progress`, `update.failed` und `agent.restarting`.
///   Abgelehnt mit 409: `update_busy`, `update_not_available`,
///   `update_unsupported`.
RouteRegistrar updateRoutes() {
  return (Router router, AgentContext ctx) {
    router
      ..get('/v1/update', (Request r) async {
        final updater = ctx.updater;
        if (updater == null) return _missing();
        return okJson((await updater.info()).toJson());
      })
      ..post('/v1/update', (Request r) async {
        final updater = ctx.updater;
        if (updater == null) return _missing();
        try {
          await updater.start();
        } on UpdateFailure catch (failure) {
          return failJson(failure.code, failure.message, status: 409);
        }
        return okJson(<String, Object?>{'started': true});
      });
  };
}

Response _missing() =>
    failJson(errorNotFound, 'Diesen Pfad gibt es nicht.', status: 404);
