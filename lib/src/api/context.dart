import 'dart:async';

import 'package:shelf_router/shelf_router.dart';

import '../config/model.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../pairing/pairing.dart';

/// Baut zusätzliche Routen in den Router des Agenten ein.
///
/// Damit hängen sich spätere Etappen (Drucker, Terminal, WebSocket-Events) an,
/// ohne `server.dart` anzufassen:
/// `buildHandler(ctx, extraRoutes: [registerPrinterRoutes])`.
typedef RouteRegistrar = void Function(Router router, AgentContext context);

/// Liefert die Druckerliste für `GET /v1/status` (Etappe A3).
typedef PrinterSummaries = FutureOr<List<Map<String, Object?>>> Function();

/// Gemeinsamer Zustand aller Endpunkte.
///
/// Die Konfiguration wird bewusst **je Anfrage frisch gelesen** statt im
/// Speicher gehalten: sie ist wenige Kilobyte groß, und nur so sieht der
/// laufende Agent auch das, was ein zweiter Prozess (`kasseneck-connect pair`)
/// in die Datei geschrieben hat.
class AgentContext {
  AgentContext({
    required this.store,
    required this.log,
    required this.startedAt,
    this.port = 0,
    DateTime Function()? clock,
    Pairing? pairing,
    PrinterSummaries? printers,
  }) : clock = clock ?? DateTime.now,
       printers = printers ?? _noPrinters {
    this.pairing =
        pairing ?? Pairing(store: store, log: log, clock: this.clock);
  }

  final ConfigStore store;

  final AgentLog log;

  /// Startzeit des Agenten (Grundlage von `uptimeSeconds`).
  final DateTime startedAt;

  /// Uhr — in Tests austauschbar.
  final DateTime Function() clock;

  /// Port, auf dem der Server tatsächlich lauscht; [Agent] setzt ihn nach dem
  /// Binden, weil erst dann feststeht, welcher Port frei war.
  int port;

  /// Kopplung: Code erzeugen, prüfen, Token ausgeben und widerrufen.
  late final Pairing pairing;

  /// Drucker für die Langform des Status (bis A3 leer).
  final PrinterSummaries printers;

  Future<AgentConfig> config() => store.load();

  int get uptimeSeconds => clock().difference(startedAt).inSeconds;

  static List<Map<String, Object?>> _noPrinters() =>
      const <Map<String, Object?>>[];
}
