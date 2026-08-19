import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../events/bus.dart';
import '../version.dart';
import 'context.dart';
import 'responses.dart';

/// Pfad des Ereignisstroms.
const String eventsPath = '/v1/events';

/// Abstand der WebSocket-Pings.
///
/// Ohne Ping merkt weder Agent noch Kasse, dass die Gegenseite weg ist — ein
/// halb offener Socket bliebe stundenlang stehen. `WebSocket.pingInterval`
/// schließt die Verbindung, wenn zwei Intervalle ohne Antwort vergehen.
const Duration eventsPingInterval = Duration(seconds: 30);

/// Begrüßung, sobald die Verbindung steht.
const String eventHello = 'hello';

/// Meldet `GET /v1/events` an.
///
/// Die Route hängt an derselben Kette wie alle anderen (Herkunft → Token);
/// ohne gültigen Token kommt es gar nicht erst zum Upgrade, der Klient sieht
/// eine 401 statt eines offenen Sockets.
RouteRegistrar eventRoutes({Duration pingInterval = eventsPingInterval}) {
  return (Router router, AgentContext context) {
    router.get(eventsPath, eventsHandler(context, pingInterval: pingInterval));
  };
}

/// Baut den WebSocket-Handler für [ctx].
///
/// Vorgeschaltet ist die Prüfung auf die Upgrade-Kopfzeilen: `shelf_web_socket`
/// beantwortet eine gewöhnliche Anfrage sonst mit einer **HTML**-Seite (404),
/// und die Kasse bekäme statt der gewohnten Fehlerhülle plötzlich Markup.
Handler eventsHandler(
  AgentContext ctx, {
  Duration pingInterval = eventsPingInterval,
}) {
  final socketHandler = webSocketHandler(
    (WebSocketChannel channel, String? _) => serveEvents(ctx, channel),
    pingInterval: pingInterval,
  );

  return (Request request) {
    if (!isWebSocketUpgrade(request)) {
      return failJson(
        errorUpgradeRequired,
        'Dieser Pfad spricht nur WebSocket.',
        status: 426,
      );
    }
    return socketHandler(request);
  };
}

/// Ob die Anfrage wirklich ein WebSocket-Upgrade ist.
bool isWebSocketUpgrade(Request request) {
  final connection = request.headers['connection'];
  final upgrade = request.headers['upgrade'];
  if (connection == null || upgrade == null) return false;
  final tokens = connection
      .toLowerCase()
      .split(',')
      .map((token) => token.trim());
  return tokens.contains('upgrade') && upgrade.toLowerCase() == 'websocket';
}

/// Bedient eine offene Verbindung: Begrüßung, dann jedes Bus-Ereignis.
///
/// Der Bus ist ein Broadcast ohne Puffer — jede Verbindung braucht ihr eigenes
/// Abo und muss es beim Schließen abbestellen, sonst schreibt der Agent bis in
/// alle Ewigkeit in eine tote Senke.
void serveEvents(AgentContext ctx, WebSocketChannel channel) {
  var closed = false;

  void send(Map<String, Object?> payload) {
    if (closed) return;
    try {
      channel.sink.add(jsonEncode(payload));
    } on Object catch (e) {
      // Der Klient ist zwischen Ereignis und Versand verschwunden, oder die
      // Senke ist schon zu. Ein Ereignis darf den Agenten nie umbringen —
      // deshalb hier bewusst alles fangen, nicht nur StateError.
      closed = true;
      ctx.log.debug('Ereignis ließ sich nicht senden: $e');
    }
  }

  send(<String, Object?>{
    'type': eventHello,
    'version': agentVersion,
    'port': ctx.port,
  });

  final subscription = ctx.events.stream.listen(
    (AgentEvent event) => send(event.toJson()),
    // Schließt der Bus (Agent hält an), geht auch diese Verbindung höflich zu,
    // statt als Leiche offen zu bleiben: der Socket ist nach dem Hijack nicht
    // mehr am HttpServer und überlebt dessen `close()` sonst.
    onDone: () {
      closed = true;
      unawaited(_closeQuietly(channel));
    },
  );

  Future<void> stop() async {
    closed = true;
    await subscription.cancel();
  }

  // Die Kasse schickt über diesen Kanal nichts; interessant ist allein das
  // Ende der Verbindung.
  channel.stream.listen(
    (Object? _) {},
    onDone: () => unawaited(stop()),
    onError: (Object _) => unawaited(stop()),
    cancelOnError: true,
  );
}

Future<void> _closeQuietly(WebSocketChannel channel) async {
  try {
    await channel.sink.close();
  } on Object {
    // Beim Anhalten interessiert kein Fehler mehr.
  }
}
