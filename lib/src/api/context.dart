import 'dart:async';

import 'package:shelf_router/shelf_router.dart';

import '../bluetooth/bridge.dart';
import '../config/model.dart';
import '../config/store.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import '../pairing/pairing.dart';
import '../update/system_info.dart';

/// Baut zusätzliche Routen in den Router des Agenten ein.
///
/// Damit hängen sich spätere Etappen (Drucker, Terminal, WebSocket-Events) an,
/// ohne `server.dart` anzufassen:
/// `buildHandler(ctx, extraRoutes: [registerPrinterRoutes])`.
typedef RouteRegistrar = void Function(Router router, AgentContext context);

/// Liefert die Druckerliste für `GET /v1/status` (Etappe A3).
typedef PrinterSummaries = FutureOr<List<Map<String, Object?>>> Function();

/// Liefert den Zertifikatsstand des HTTPS-Zugangs für die Langform des
/// Status (`tls`), `null` ohne Zertifikat.
typedef TlsSummary = Future<Map<String, Object?>?> Function();

/// Liefert Betriebssystem, Systemversion und Prozessor für die Langform des
/// Status.
typedef SystemInfoReader = Future<SystemInfo> Function();

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
    EventBus? events,
    this.environment,
    this.bluetooth,
  }) : clock = clock ?? DateTime.now,
       events = events ?? EventBus(),
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

  /// Port des HTTPS-Zugangs, `null`, solange er nicht lauscht (außerhalb von
  /// macOS immer). [Agent] setzt ihn nach jedem Binden und nimmt ihn weg,
  /// sobald der Zugang schließt — daran hängt `features: https`.
  int? httpsPort;

  /// Zertifikatsstand für die Langform des Status; `null` ohne HTTPS.
  TlsSummary? tls;

  /// Systemversion und Prozessor für die Langform des Status; `null` lässt
  /// die beiden Felder weg. [Agent] setzt es beim Start.
  SystemInfoReader? systemInfo;

  /// Kopplung: Code erzeugen, prüfen, Token ausgeben und widerrufen.
  late final Pairing pairing;

  /// Drucker für die Langform des Status.
  final PrinterSummaries printers;

  /// Gemeinsamer Ereignisbus (Druck, Druckerzustand, später Terminal).
  ///
  /// Die Melder schreiben hier hinein; `/v1/events` (Etappe A4) hängt sich als
  /// Zuhörer daran.
  final EventBus events;

  /// Umgebungsvariablen für die Endpunkte (`null` = die des Prozesses).
  ///
  /// Gebraucht wird das bisher nur für `KASSENECK_CONNECT_NO_BROWSER`: so
  /// entscheidet im Test der Test darüber, ob ein Browser aufginge — und nicht
  /// die Umgebung des Rechners, auf dem er läuft.
  final Map<String, String>? environment;

  /// Bluetooth-Brücke des Agenten, `null` ohne Bluetooth (z. B. in Tests).
  ///
  /// `GET /v1/status` liest daraus `features` und den Bluetooth-Zustand; ohne
  /// Brücke antworten alle Bluetooth-Pfade `bluetooth_unsupported`.
  final BluetoothBridge? bluetooth;

  /// Zeitpunkt der letzten Kopplungsanforderung über `POST /v1/pair/request`.
  ///
  /// Bewusst nur im Speicher und nicht in der `config.json`: die Bremse soll
  /// verhindern, dass eine Kasse dem Benutzer Browserfenster ins Gesicht
  /// wirft — sie muss keinen Neustart überdauern.
  DateTime? lastPairRequestAt;

  Future<AgentConfig> config() => store.load();

  int get uptimeSeconds => clock().difference(startedAt).inSeconds;

  static List<Map<String, Object?>> _noPrinters() =>
      const <Map<String, Object?>>[];
}
