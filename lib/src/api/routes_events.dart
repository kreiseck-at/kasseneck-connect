import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../events/bus.dart';
import '../version.dart';
import 'context.dart';

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
Handler eventsHandler(
  AgentContext ctx, {
  Duration pingInterval = eventsPingInterval,
}) {
  return webSocketHandler(
    (WebSocketChannel channel, String? _) => serveEvents(ctx, channel),
    pingInterval: pingInterval,
  );
}

/// Bedient eine offene Verbindung: Begrüßung, dann jedes Bus-Ereignis.
///
/// Der Bus ist ein Broadcast ohne Puffer — jede Verbindung braucht ihr eigenes
/// Abo und muss es beim Schließen abbestellen, sonst schreibt der Agent bis in
/// alle Ewigkeit in eine tote Senke.
void serveEvents(AgentContext ctx, WebSocketChannel channel) {
  void send(Map<String, Object?> payload) {
    try {
      channel.sink.add(jsonEncode(payload));
    } on StateError {
      // Der Klient ist zwischen Ereignis und Versand verschwunden.
    }
  }

  send(<String, Object?>{
    'type': eventHello,
    'version': agentVersion,
    'port': ctx.port,
  });

  final subscription = ctx.events.stream.listen(
    (AgentEvent event) => send(event.toJson()),
  );

  Future<void> stop() async {
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
