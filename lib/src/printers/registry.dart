import 'dart:async';
import 'dart:math';

import '../config/model.dart';
import '../config/store.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import 'driver.dart';
import 'epos.dart';
import 'tcp9100.dart';

/// Zeichenvorrat der Drucker-IDs (Base32 ohne verwechselbare Zeichen).
const String printerIdAlphabet = 'abcdefghijklmnopqrstuvwxyz234567';

/// Länge des Zufallsteils einer Drucker-ID.
const int printerIdLength = 8;

/// Präfix aller Drucker-IDs.
const String printerIdPrefix = 'p_';

/// Zeitlimit einer Zustandsabfrage; kürzer als ein Druckversuch, weil die
/// Kasse beim Öffnen der Einstellungen nicht warten soll.
const Duration defaultProbeTimeout = Duration(seconds: 2);

/// Verwaltet die konfigurierten Drucker und ihre Treiber.
///
/// Die Liste steht in der `config.json`; geschrieben wird ausschließlich über
/// [ConfigStore.mutate], damit ein zweiter Prozess nichts überschreibt. Der
/// zuletzt bekannte Zustand je Drucker liegt dagegen nur im Speicher — er
/// altert sofort und hat in einer Datei nichts verloren.
class PrinterRegistry {
  PrinterRegistry({
    required this.store,
    AgentLog? log,
    EventBus? events,
    Random? random,
    PrinterDriver Function(PrinterConfig printer)? driverFactory,
    this.probeTimeout = defaultProbeTimeout,
  }) : _log = log,
       _events = events,
       _random = random ?? Random.secure(),
       _driverFactory = driverFactory;

  final ConfigStore store;
  final AgentLog? _log;
  final EventBus? _events;
  final Random _random;
  final PrinterDriver Function(PrinterConfig printer)? _driverFactory;

  /// Zeitlimit einer Zustandsabfrage.
  final Duration probeTimeout;

  final Map<String, PrinterState> _states = <String, PrinterState>{};

  /// Alle konfigurierten Drucker in Reihenfolge der Konfiguration.
  Future<List<PrinterConfig>> list() async => (await store.load()).printers;

  /// Ein Drucker oder `null`.
  Future<PrinterConfig?> find(String id) async {
    for (final printer in await list()) {
      if (printer.id == id) return printer;
    }
    return null;
  }

  /// Legt einen Drucker an oder ersetzt ihn.
  ///
  /// Ist [printer].id leer, vergibt der Agent eine neue ID — die Kasse denkt
  /// sich keine IDs aus. Zeigt dabei schon ein Drucker auf dieselbe Adresse
  /// (`host:port`), wird **dieser** aktualisiert statt ein zweiter angelegt:
  /// die Kasse schickt beim erneuten Einrichten denselben Drucker noch einmal,
  /// und zwei Einträge auf ein Gerät hießen jeden Bon doppelt. Wer wirklich
  /// zwei Einträge auf eine Adresse will, gibt eine ID mit — dann greift die
  /// Adressprüfung nicht.
  ///
  /// Die Suche nach dem Zwilling steht mit in [ConfigStore.mutate], damit zwei
  /// gleichzeitige Anfragen nicht doch zwei Einträge erzeugen.
  Future<PrinterConfig> upsert(PrinterConfig printer) async {
    late PrinterConfig saved;

    await store.mutate((config) {
      final printers = config.printers.toList();
      saved = printer.id.isEmpty
          ? printer.copyWith(id: _idForAddress(printers, printer))
          : printer;
      final index = printers.indexWhere((e) => e.id == saved.id);
      if (index >= 0) {
        printers[index] = saved;
      } else {
        printers.add(saved);
      }
      return config.copyWith(printers: printers);
    });

    _log?.info('Drucker ${saved.id} gespeichert (${saved.kind.wireName}).');
    return saved;
  }

  /// ID des Druckers an derselben Adresse — sonst eine frische.
  String _idForAddress(List<PrinterConfig> printers, PrinterConfig wanted) {
    final host = wanted.host.toLowerCase();
    for (final printer in printers) {
      if (printer.host.toLowerCase() == host && printer.port == wanted.port) {
        return printer.id;
      }
    }
    return newId();
  }

  /// Entfernt einen Drucker; `false`, wenn es ihn nicht gab.
  Future<bool> remove(String id) async {
    var removed = false;
    await store.mutate((config) {
      final printers = config.printers.where((e) => e.id != id).toList();
      removed = printers.length != config.printers.length;
      return removed ? config.copyWith(printers: printers) : config;
    });
    if (removed) {
      _states.remove(id);
      _log?.info('Drucker $id entfernt.');
    }
    return removed;
  }

  /// Erzeugt eine neue, kurze Drucker-ID.
  String newId() {
    final buffer = StringBuffer(printerIdPrefix);
    for (var i = 0; i < printerIdLength; i++) {
      buffer.write(
        printerIdAlphabet[_random.nextInt(printerIdAlphabet.length)],
      );
    }
    return buffer.toString();
  }

  /// Baut den Treiber zu einem Drucker.
  ///
  /// ePOS über HTTPS wird **allein am Port 443** erkannt: die Konfiguration
  /// führt kein eigenes Feld dafür, und ein Drucker, der sein ePOS auf 443
  /// anbietet, spricht dort ausschließlich TLS. Jeder andere Port gilt als
  /// Klartext — auch 8443 oder 10443. Wer TLS auf einem krummen Port braucht,
  /// bekommt dafür ein eigenes Feld in der Konfiguration, keine Rateregel.
  PrinterDriver driverFor(PrinterConfig printer) {
    final factory = _driverFactory;
    if (factory != null) return factory(printer);

    switch (printer.kind) {
      case PrinterKind.tcp9100:
        return Tcp9100Printer(printer.host, printer.port);
      case PrinterKind.epos:
        final https = printer.port == 443;
        final standard = https || printer.port == 80;
        return EposPrinter(
          printer.host,
          port: standard ? null : printer.port,
          https: https,
          devid: printer.devid ?? defaultEposDevid,
        );
    }
  }

  /// Treiber zu einer ID oder `null`, wenn der Drucker unbekannt ist.
  Future<PrinterDriver?> driverForId(String id) async {
    final printer = await find(id);
    return printer == null ? null : driverFor(printer);
  }

  /// Zuletzt bekannter Zustand (ohne Abfrage).
  PrinterState stateOf(String id) => _states[id] ?? PrinterState.unknown;

  /// Merkt sich einen Zustand und meldet die Änderung auf dem Ereignisbus.
  void noteState(String id, PrinterState state) {
    if (_states[id] == state) return;
    _states[id] = state;
    _events?.publish(eventPrinterState, <String, Object?>{
      'printerId': id,
      'state': state.wireName,
    });
  }

  /// Drucker samt Zustand für `GET /v1/printers` und die Langform des Status.
  ///
  /// [probe] fragt die Geräte parallel ab; ohne [probe] kommt der zuletzt
  /// bekannte Zustand — der Status soll niemals auf Netzwerk warten.
  Future<List<Map<String, Object?>>> summaries({bool probe = false}) async {
    final printers = await list();
    if (probe) {
      await Future.wait(printers.map(_probe));
    }
    return printers
        .map(
          (printer) => <String, Object?>{
            ...printer.toJson(),
            'state': stateOf(printer.id).wireName,
          },
        )
        .toList();
  }

  Future<void> _probe(PrinterConfig printer) async {
    try {
      final state = await driverFor(printer)
          .status(timeout: probeTimeout)
          .timeout(probeTimeout, onTimeout: () => PrinterState.offline);
      noteState(printer.id, state);
    } on Object catch (e) {
      _log?.warn('Zustand von ${printer.id} nicht ermittelbar: $e');
      noteState(printer.id, PrinterState.offline);
    }
  }
}
