import 'dart:async';
import 'dart:math';

import '../config/model.dart';
import '../config/store.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import 'driver.dart';
import 'epos.dart';
import 'kennung.dart';
import 'lage.dart';
import 'tcp9100.dart';
import 'zustand.dart';

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
    DruckerLagen? lagen,
    SocketConnector? verbinden,
    HttpVerbinder? eposVerbinden,
  }) : _verbinden = verbinden,
       _eposVerbinden = eposVerbinden,
       _log = log,
       _events = events,
       _random = random ?? Random.secure(),
       _driverFactory = driverFactory,
       lagen = lagen ?? DruckerLagen();

  final ConfigStore store;
  final AgentLog? _log;
  final EventBus? _events;
  final Random _random;
  final PrinterDriver Function(PrinterConfig printer)? _driverFactory;

  /// Verbindungsaufbau der 9100-Treiber (Tests ersetzen ihn); `null`:
  /// `Socket.connect`.
  final SocketConnector? _verbinden;

  /// Verbindungsaufbau der ePOS-Treiber (Tests ersetzen ihn); `null`: der
  /// des `HttpClient`.
  final HttpVerbinder? _eposVerbinden;

  /// Zeitlimit einer Zustandsabfrage.
  final Duration probeTimeout;

  final Map<String, PrinterState> _states = <String, PrinterState>{};

  /// Was Connect im Lauf über jeden Drucker weiß (Kennung, Papier, Deckel).
  final DruckerLagen lagen;

  /// Alle konfigurierten Drucker in Reihenfolge der Konfiguration.
  Future<List<PrinterConfig>> list() async => (await store.load()).printers;

  /// Ein Drucker oder `null`.
  Future<PrinterConfig?> find(String id) async {
    for (final printer in await list()) {
      if (printer.id == id) return printer;
    }
    return null;
  }

  /// Laufende Schreibvorgänge im Hintergrund ([imHintergrund]).
  final Set<Future<void>> _hintergrund = <Future<void>>{};

  /// Führt [arbeit] im Hintergrund aus: Druck und Statustakt warten nie auf
  /// die `config.json` – hielte ein anderer Prozess die Sperre, stünde sonst
  /// der Bon. Fehler landen im Log. [hintergrundErledigt] wartet darauf.
  void imHintergrund(String was, Future<void> Function() arbeit) {
    late final Future<void> lauf;
    lauf = Future<void>(arbeit)
        .catchError((Object e) {
          _log?.warn('$was: $e');
        })
        .whenComplete(() {
          // Block statt Pfeil: `remove` liefert einen Wahrheitswert.
          _hintergrund.remove(lauf);
        });
    _hintergrund.add(lauf);
  }

  /// Wartet auf alle Schreibvorgänge im Hintergrund (Anhalten, Tests).
  Future<void> hintergrundErledigt() async {
    while (_hintergrund.isNotEmpty) {
      await Future.wait(_hintergrund.toList());
    }
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
    var konfliktAufgeloest = false;

    await store.mutate((config) {
      final printers = config.printers.toList();
      saved = printer.id.isEmpty
          ? printer.copyWith(id: _idForAddress(printers, printer))
          : printer;
      final index = printers.indexWhere((e) => e.id == saved.id);
      if (index >= 0) {
        // Ein Konflikt heißt: unter der Adresse steht nachweislich ein anderes
        // Gerät. Richtet die Kasse den Drucker dort neu ein, ist es gewollt –
        // die alte Kennung gilt nicht mehr.
        final konflikt =
            lagen.vorhanden(saved.id)?.kennung == KennungsLage.konflikt &&
            _gleicheAdresse(printers[index], saved);
        konfliktAufgeloest = konflikt && printers[index].hatKennung;
        saved = behalteKennung(
          printers[index],
          saved,
          kennungVerwerfen: konflikt,
        );
        printers[index] = saved;
      } else {
        printers.add(saved);
      }
      return config.copyWith(printers: printers);
    });
    // Eine ausdrückliche Einrichtung beginnt den Laufzeitstand neu (Papier,
    // Kennungslage, „stumm“): womöglich steht dort ein anderes Gerät.
    lagen.vergiss(saved.id);

    _log?.info('Drucker ${saved.id} gespeichert (${saved.kind.wireName}).');
    if (konfliktAufgeloest) {
      _log?.info(
        'Drucker ${saved.id}: Kennungskonflikt durch Neueinrichtung '
        'aufgelöst – die Kennung wird neu ermittelt.',
      );
    }
    return saved;
  }

  /// Der neue Eintrag [neu] mit Kennung und fremden Feldern des bisherigen
  /// [alt], solange Adresse und Anbindung gleich bleiben.
  ///
  /// Die Kasse schickt beim erneuten Einrichten denselben Drucker noch einmal,
  /// ohne Kennung; die soll dabei nicht verloren gehen – außer mit
  /// [kennungVerwerfen] (Neueinrichtung im Kennungskonflikt). Zeigt der
  /// Eintrag auf eine andere Adresse, kann dort ein anderes Gerät stehen –
  /// dann beginnt die Kennung neu.
  ///
  /// `statusCapableAt` übernimmt die Neueinrichtung nie: hängt unter der
  /// Adresse inzwischen ein Gerät, das nie auf `DLE EOT` antwortet, hieße sein
  /// Schweigen sonst „nicht bereit“. Die nächste gültige Antwort setzt es neu.
  static PrinterConfig behalteKennung(
    PrinterConfig alt,
    PrinterConfig neu, {
    bool kennungVerwerfen = false,
  }) {
    if (!_gleicheAdresse(alt, neu)) return neu;
    final kennung = !kennungVerwerfen;
    return PrinterConfig(
      id: neu.id,
      name: neu.name,
      kind: neu.kind,
      host: neu.host,
      port: neu.port,
      devid: neu.devid,
      model: kennung ? alt.model : null,
      serial: kennung ? alt.serial : null,
      mac: kennung ? alt.mac : null,
      identifiedAt: kennung ? alt.identifiedAt : null,
      identitySource: kennung ? alt.identitySource : null,
      extras: alt.extras,
    );
  }

  static bool _gleicheAdresse(PrinterConfig a, PrinterConfig b) =>
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port &&
      a.kind == b.kind;

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
      lagen.vergiss(id);
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
        return Tcp9100Printer(
          printer.host,
          printer.port,
          verbinden: _verbinden,
        );
      case PrinterKind.epos:
        final https = printer.port == 443;
        final standard = https || printer.port == 80;
        return EposPrinter(
          printer.host,
          port: standard ? null : printer.port,
          https: https,
          devid: printer.devid ?? defaultEposDevid,
          verbinden: _eposVerbinden,
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
    final lage = lagen.vorhanden(id);
    _events?.publish(eventPrinterState, <String, Object?>{
      'printerId': id,
      'state': state.wireName,
      if (lage != null && lage.zustandAm != null) ..._zustandsFelder(lage),
    });
  }

  /// Merkt sich im Hintergrund: [drucker] antwortet auf `DLE EOT`
  /// (`statusCapableAt`). Einmal je Drucker und Adresse; wirft nie.
  void statusfaehigMerken(PrinterConfig drucker, DateTime am) {
    if (drucker.statusCapableAt != null) return;
    imHintergrund(
      'Drucker ${drucker.id}: Statusfähigkeit',
      () => _statusfaehigSchreiben(drucker, am),
    );
  }

  Future<void> _statusfaehigSchreiben(
    PrinterConfig drucker,
    DateTime am,
  ) async {
    try {
      await store.mutate((config) {
        final printers = config.printers.toList();
        final index = printers.indexWhere((p) => p.id == drucker.id);
        if (index < 0) return config;
        final aktuell = printers[index];
        if (aktuell.statusCapableAt != null ||
            aktuell.host != drucker.host ||
            aktuell.port != drucker.port) {
          return config;
        }
        printers[index] = aktuell.copyWith(statusCapableAt: am.toUtc());
        return config.copyWith(printers: printers);
      });
      _log?.info('Drucker ${drucker.id} antwortet auf DLE EOT.');
    } on Object catch (e) {
      // Dann gilt er weiter als nie geantwortet: Schweigen heißt unbekannt,
      // gedruckt wird wie bis 1.4.2.
      _log?.warn(
        'Drucker ${drucker.id}: Statusfähigkeit nicht gespeichert: $e',
      );
    }
  }

  /// Papier und Deckel eines ePOS-Druckers über einen leeren Auftrag; `null`,
  /// wenn er nicht antwortet oder kein ePOS-Drucker ist. Wirft nie.
  Future<DruckerZustand?> eposZustand(
    PrinterConfig printer,
    Duration frist,
  ) async {
    final treiber = driverFor(printer);
    if (treiber is! EposPrinter) return null;
    final antwort = await treiber.statusbits(timeout: frist);
    return antwort == null ? null : zustandAusEposStatus(antwort.status);
  }

  /// Merkt sich Papier und Deckel und meldet eine Änderung als
  /// `printer.state` (mit `state`, `paper`, `cover`, `statusAt`).
  void noteZustand(String id, DruckerZustand zustand, DateTime am) {
    final lage = lagen.von(id);
    final geaendert = lage.zustand != zustand;
    lage
      ..zustand = zustand
      ..zustandAm = am.toUtc();
    if (!geaendert) return;
    _events?.publish(eventPrinterState, <String, Object?>{
      'printerId': id,
      'state': stateOf(id).wireName,
      ..._zustandsFelder(lage),
    });
  }

  static Map<String, Object?> _zustandsFelder(DruckerLage lage) =>
      <String, Object?>{
        'paper': lage.zustand.papier.wireName,
        'cover': lage.zustand.deckel.wireName,
        'readiness': lage.zustand.bereitschaft.wireName,
        'statusAt': lage.zustandAm?.toIso8601String(),
      };

  /// Drucker samt Zustand für `GET /v1/printers` und die Langform des Status.
  ///
  /// [probe] fragt die Geräte parallel ab; ohne [probe] kommt der zuletzt
  /// bekannte Zustand — der Status soll niemals auf Netzwerk warten.
  Future<List<Map<String, Object?>>> summaries({bool probe = false}) async {
    final printers = await list();
    if (probe) {
      await Future.wait(printers.map(_probe));
    }
    return printers.map(zusammenfassung).toList();
  }

  /// Ein Drucker für die API: die Felder aus 1.4.2 (`toApiJson`, `state`),
  /// dazu ab 1.5.0 `paper`, `cover`, `statusAt` und `identity`.
  ///
  /// Neue Felder stehen nur da, wenn sie etwas sagen: ein Drucker, über den
  /// nichts bekannt ist, sieht aus wie in 1.4.2 (fehlend heißt unbekannt).
  Map<String, Object?> zusammenfassung(PrinterConfig printer) {
    final lage = lagen.vorhanden(printer.id);
    final kennung = lage?.kennung ?? KennungsLage.unbekannt;
    final mitKennung =
        printer.model != null ||
        printer.hatKennung ||
        kennung != KennungsLage.unbekannt;
    return <String, Object?>{
      ...printer.toApiJson(),
      'state': stateOf(printer.id).wireName,
      if (lage != null && lage.zustandAm != null) ..._zustandsFelder(lage),
      if (mitKennung)
        'identity': <String, Object?>{
          'model': printer.model,
          'serial': printer.serial,
          'mac': printer.mac,
          'state': kennung.wireName,
        },
    };
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
