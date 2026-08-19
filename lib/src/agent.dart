import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import 'api/context.dart';
import 'api/routes_events.dart';
import 'api/routes_printers.dart';
import 'api/server.dart';
import 'config/model.dart';
import 'config/store.dart';
import 'events/bus.dart';
import 'log/logger.dart';
import 'pairing/pairing.dart';
import 'printers/discovery.dart';
import 'printers/queue.dart';
import 'printers/registry.dart';
import 'version.dart';

/// Wie viele Ports der Agent ab dem Wunschport durchprobiert
/// (27182 … 27189).
const int portFallbackRange = 8;

/// So lange darf das höfliche Schließen dauern, bevor hart geschlossen wird.
const Duration gracefulStopTimeout = Duration(seconds: 2);

/// Der laufende Agent: lokaler HTTP-Server auf 127.0.0.1 samt Kopplung.
///
/// Gebunden wird ausschließlich die Loopback-Adresse — aus dem LAN ist der
/// Agent damit gar nicht erreichbar.
class Agent {
  Agent({
    required this.store,
    required this.log,
    this.preferredPort = defaultAgentPort,
    DateTime Function()? clock,
    Pairing? pairing,
    List<RouteRegistrar> extraRoutes = const <RouteRegistrar>[],
    bool? openBrowser,
    Map<String, String>? environment,
    EventBus? events,
    PrinterRegistry? registry,
    PrintQueue? queue,
    PrinterDiscovery? discovery,
  }) : _clock = clock ?? DateTime.now,
       _pairing = pairing,
       _extraRoutes = extraRoutes,
       _openBrowser = openBrowser,
       _environment = environment,
       _events = events,
       _registry = registry,
       _queue = queue,
       _discovery = discovery;

  final ConfigStore store;
  final AgentLog log;

  /// Wunschport; von dort an wird bis [portFallbackRange] Ports weit gesucht.
  /// `0` bindet einen freien Port des Systems (Tests).
  final int preferredPort;

  final DateTime Function() _clock;
  final Pairing? _pairing;
  final List<RouteRegistrar> _extraRoutes;
  final bool? _openBrowser;
  final Map<String, String>? _environment;
  final EventBus? _events;
  final PrinterRegistry? _registry;
  final PrintQueue? _queue;
  final PrinterDiscovery? _discovery;

  HttpServer? _server;
  AgentContext? _context;
  PrinterRegistry? _printers;
  List<RouteRegistrar> _routes = const <RouteRegistrar>[];

  /// Ob der Bus dem Agenten gehört. Einen von außen hereingereichten Bus
  /// (Tests, spätere Etappen) darf [stop] nicht schließen — der Besitzer
  /// entscheidet über sein Lebensende.
  bool _ownsEvents = false;

  /// Druckerverwaltung des laufenden Agenten (erst nach [start] gültig).
  PrinterRegistry get printers {
    final registry = _printers;
    if (registry == null) {
      throw StateError('Der Agent läuft nicht — zuerst start() aufrufen.');
    }
    return registry;
  }

  /// Ereignisbus des laufenden Agenten (erst nach [start] gültig).
  EventBus get events => context.events;

  /// Port, auf dem der Agent tatsächlich lauscht (erst nach [start] gültig).
  int get port => _server?.port ?? 0;

  /// Zustand für die Endpunkte (erst nach [start] gültig).
  AgentContext get context {
    final ctx = _context;
    if (ctx == null) {
      throw StateError('Der Agent läuft nicht — zuerst start() aufrufen.');
    }
    return ctx;
  }

  /// Startet den Server, merkt sich den Port und stößt bei Bedarf die
  /// Kopplung an (Code erzeugen, loggen, Browser öffnen).
  Future<void> start() async {
    if (_server != null) return;

    // Der Druckstapel gehört zum Agenten: Registry, Warteschlange und Suche
    // hängen alle am selben Ereignisbus, den A4 an `/v1/events` weiterreicht.
    final bus = _events ?? EventBus();
    _ownsEvents = _events == null;
    final registry =
        _registry ?? PrinterRegistry(store: store, log: log, events: bus);
    final queue =
        _queue ?? PrintQueue(registry: registry, events: bus, log: log);
    _printers = registry;

    final ctx = AgentContext(
      store: store,
      log: log,
      startedAt: _clock(),
      clock: _clock,
      pairing: _pairing,
      events: bus,
      printers: registry.summaries,
    );
    _context = ctx;
    _routes = <RouteRegistrar>[
      eventRoutes(),
      printerRoutes(
        registry: registry,
        queue: queue,
        discovery: _discovery ?? PrinterDiscovery(log: log),
      ),
      ..._extraRoutes,
    ];

    final server = await _bind();
    _server = server;
    ctx.port = server.port;
    log.info(
      '$agentName $agentVersion lauscht auf http://127.0.0.1:${server.port}',
    );

    final config = await store.load();
    if (config.port != server.port) {
      await store.mutate((current) => current.copyWith(port: server.port));
    }

    if (config.tokenHashes.isEmpty) {
      final code = await ctx.pairing.newCode();
      log.info('Kopplungscode $code (10 Minuten gültig).');
      if (_openBrowser ?? true) {
        await ctx.pairing.openPairingPage(code, server.port);
      }
    }
  }

  /// Hält den Server an: erst höflich (laufende Anfragen dürfen zu Ende
  /// gehen), nach [gracefulStopTimeout] mit Nachdruck.
  Future<void> stop() async {
    final server = _server;
    final ctx = _context;
    _server = null;
    _context = null;
    if (server == null) return;

    // Zuerst der Bus: die offenen WebSocket-Verbindungen hängen nach dem
    // Hijack nicht mehr am HttpServer und überlebten dessen `close()`. Mit dem
    // Bus endet ihr Abo, und `serveEvents` schließt daraufhin die Senke —
    // die Kasse sieht ein sauberes Ende statt einer Verbindung ins Nichts.
    if (ctx != null && _ownsEvents) {
      await ctx.events.close();
    }

    try {
      await server.close().timeout(gracefulStopTimeout);
    } on TimeoutException {
      log.warn('Anfragen hängen — Server wird hart geschlossen.');
      await server.close(force: true);
    }
    log.info('Agent angehalten.');
  }

  /// Bindet den ersten freien Port ab [preferredPort].
  Future<HttpServer> _bind() async {
    final handler = buildHandler(
      context,
      extraRoutes: _routes,
      environment: _environment,
    );
    final attempts = preferredPort == 0 ? 1 : portFallbackRange;
    Object? lastError;

    for (var offset = 0; offset < attempts; offset++) {
      final candidate = preferredPort == 0 ? 0 : preferredPort + offset;
      try {
        return await shelf_io.serve(
          handler,
          InternetAddress.loopbackIPv4,
          candidate,
        );
      } on SocketException catch (e) {
        lastError = e;
        log.warn('Port $candidate ist belegt — nächster Versuch.');
      }
    }

    log.error('Kein freier Port ab $preferredPort gefunden', lastError);
    throw StateError(
      'Kein freier Port zwischen $preferredPort und '
      '${preferredPort + portFallbackRange - 1}.',
    );
  }
}
