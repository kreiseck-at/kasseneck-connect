import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../log/logger.dart';
import '../net/arp.dart';
import 'abfrage.dart';
import 'discovery.dart' show InterfaceProbe;
import 'driver.dart';
import 'erkennung.dart' show macImSelbenNetz;
import 'kennung.dart';
import 'lage.dart';
import 'queue.dart';
import 'registry.dart';
import 'zustand.dart';

/// Abstand des Statustakts (Spec 1.4). Eine Minute: Papierende fällt so vor
/// dem übernächsten Gast auf, und ein Drucker sieht dabei höchstens eine
/// kurze Verbindung je Minute.
const Duration statusTaktAbstand = Duration(seconds: 60);

/// Eine Kasse gilt als offen, solange sie in diesem Fenster eine Anfrage mit
/// gültigem Token geschickt hat (Spec 1.4: zwei Minuten). Ohne offene Kasse
/// kein Takt – nachts spricht Connect nicht mit den Druckern.
const Duration kasseOffenFenster = Duration(minutes: 2);

/// Zeitbudget einer Statusabfrage im Takt und auf Zuruf. Niemand wartet an
/// der Kasse darauf; zwei Sekunden wie bei der Zustandsabfrage aus 1.4.2.
const Duration statusAbrufBudget = defaultProbeTimeout;

/// So oft hintereinander darf der Takt einen Drucker nicht sehen, bevor die
/// gründliche Suche nach ihm beginnt (Spec 1.3).
const int verfehltBisSuche = 2;

/// Fragt Papier, Deckel und Erreichbarkeit der Drucker ab – auf Zuruf
/// (`POST /v1/printers/{id}/status`) und im Takt, solange eine Kasse offen
/// ist.
///
/// Alles läuft über die Warteschlange des Druckers ([PrintQueue.exclusive]):
/// nie neben einem Bon. Der Takt ist einer für alle Drucker, gleich wie viele
/// Kassen offen sind.
class DruckerStatusDienst {
  DruckerStatusDienst({
    required this.registry,
    required this.queue,
    required EscPosAbfrage abfrage,
    required DateTime? Function() kasseZuletzt,
    this.beiDauerndVerfehlt,
    ArpTabelle? arp,
    InterfaceProbe? schnittstellen,
    AgentLog? log,
    DateTime Function()? clock,
    this.abstand = statusTaktAbstand,
    this.budget = statusAbrufBudget,
  }) : _abfrage = abfrage,
       _arp = arp,
       _schnittstellen = schnittstellen,
       _kasseZuletzt = kasseZuletzt,
       _log = log,
       _clock = clock ?? DateTime.now;

  final PrinterRegistry registry;
  final PrintQueue queue;
  final EscPosAbfrage _abfrage;

  /// ARP-Tabelle und Schnittstellen für den MAC-Vergleich: nur bei gleicher
  /// MAC (oder frisch bestätigter Kennung) heißt Schweigen „nicht bereit“.
  /// Ohne sie zählt allein die frische Kennung.
  final ArpTabelle? _arp;
  final InterfaceProbe? _schnittstellen;
  final DateTime? Function() _kasseZuletzt;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Wird gerufen, wenn der Takt einen Drucker [verfehltBisSuche]-mal
  /// hintereinander nicht sah (die gründliche Suche hängt sich hier an).
  void Function(String printerId)? beiDauerndVerfehlt;

  final Duration abstand;
  final Duration budget;

  Timer? _timer;
  Future<void>? _runde;

  /// Wie viele Runden der Takt gedreht hat (Tests).
  int runden = 0;

  /// Startet den Takt (einmal je Agent).
  void start() {
    _timer ??= Timer.periodic(abstand, (_) => unawaited(runde()));
  }

  /// Hält den Takt an und wartet eine laufende Runde ab.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _runde;
  }

  /// Ob gerade eine Kasse offen ist.
  bool get kasseOffen {
    final zuletzt = _kasseZuletzt();
    if (zuletzt == null) return false;
    final alter = _clock().difference(zuletzt);
    return !alter.isNegative && alter <= kasseOffenFenster;
  }

  /// Eine Runde des Takts. Überschneidet sich nie mit einer laufenden.
  Future<void> runde() => _runde ??= _drehen().whenComplete(() {
    _runde = null;
  });

  Future<void> _drehen() async {
    try {
      final config = await registry.store.load();
      if (!config.aktiv(Neuerung.statusTakt) || !kasseOffen) return;
      runden++;
      final jetzt = _clock();
      await Future.wait(
        config.printers.map((drucker) async {
          // Ein Bon aus diesem Prozess druckt womöglich noch: der Drucker war
          // eben erreichbar, und eine Abfrage jetzt bewiese nichts.
          if (registry.lagen.vorhanden(drucker.id)?.druckt(jetzt) ?? false) {
            _zaehle(drucker.id, true);
            return;
          }
          final erreichbar = await queue.exclusive(
            drucker.id,
            () => _abfragen(drucker, config),
          );
          _zaehle(drucker.id, erreichbar);
        }),
      );
    } on Object catch (e) {
      // Der Takt ist ein Zusatz; ein Fehler darin hält nichts auf.
      _log?.warn('Statustakt: $e');
    }
  }

  void _zaehle(String id, bool erreichbar) {
    final lage = registry.lagen.von(id);
    if (erreichbar) {
      lage.verfehltInFolge = 0;
      return;
    }
    lage.verfehltInFolge++;
    if (lage.verfehltInFolge == verfehltBisSuche) {
      beiDauerndVerfehlt?.call(id);
    }
  }

  /// Fragt [id] sofort ab (über die Warteschlange) und liefert den Drucker
  /// für die API; `null`, wenn es ihn nicht gibt.
  Future<Map<String, Object?>?> jetzt(String id) async {
    final config = await registry.store.load();
    PrinterConfig? drucker;
    for (final eintrag in config.printers) {
      if (eintrag.id == id) drucker = eintrag;
    }
    if (drucker == null) return null;
    final gefunden = drucker;
    await queue.exclusive(id, () => _abfragen(gefunden, config));
    return registry.zusammenfassung(gefunden);
  }

  /// Eine Abfrage; `true`, wenn das Gerät erreichbar war. Wirft nie.
  Future<bool> _abfragen(PrinterConfig drucker, AgentConfig config) async {
    final jetzt = _clock();
    final lage = registry.lagen.von(drucker.id);
    if (!config.aktiv(Neuerung.druckerStatus)) return _nurErreichbar(drucker);

    switch (drucker.kind) {
      case PrinterKind.tcp9100:
        final statusfaehig = drucker.statusCapableAt != null;
        // Ein stummes Gerät, das nie geantwortet hat, bekommt keine Abfrage,
        // nur den Verbindungstest wie bis 1.4.2.
        if (!statusfaehig && lage.stumm(jetzt)) return _nurErreichbar(drucker);
        const fragen = <EscPosFrage>{EscPosFrage.rollensensor};
        final antworten = statusfaehig
            ? await _abfrage.frageBereit(
                drucker.host,
                drucker.port,
                fragen: fragen,
                budget: budget,
              )
            : await _abfrage.frage(
                drucker.host,
                drucker.port,
                fragen: fragen,
                budget: budget,
              );
        registry.noteState(
          drucker.id,
          antworten.verbunden ? PrinterState.online : PrinterState.offline,
        );
        if (!antworten.verbunden) return false;
        final mac = await _macVergleich(drucker);
        if (antworten.stumm) {
          if (!statusfaehig) {
            if (!lage.druckt(jetzt)) _alsStumm(drucker, lage, jetzt);
            return true;
          }
          registry.noteZustand(
            drucker.id,
            schweigenHeisstNichtBereit(mac: mac, lage: lage, jetzt: jetzt)
                ? DruckerZustand.nichtBereit
                : DruckerZustand.unbekannt,
            jetzt,
          );
          return true;
        }
        if (antworten.offlineGrund != null && mac != MacVergleich.anders) {
          registry.statusfaehigMerken(drucker, jetzt);
        }
        registry.noteZustand(
          drucker.id,
          zustandAusDleEot(
            offlineGrund: antworten.offlineGrund,
            rollensensor: antworten.rollensensor,
          ),
          jetzt,
        );
        return true;
      case PrinterKind.epos:
        final zustand = await registry.eposZustand(drucker, budget);
        registry.noteState(
          drucker.id,
          zustand == null ? PrinterState.offline : PrinterState.online,
        );
        if (zustand != null) registry.noteZustand(drucker.id, zustand, jetzt);
        return zustand != null;
    }
  }

  /// Gespeicherte gegen gesehene MAC (ohne ARP-Tabelle: unbekannt).
  Future<MacVergleich> _macVergleich(PrinterConfig drucker) async {
    final arp = _arp;
    final schnittstellen = _schnittstellen;
    if (drucker.mac == null || arp == null || schnittstellen == null) {
      return MacVergleich.unbekannt;
    }
    final gesehen = await macImSelbenNetz(drucker.host, arp, schnittstellen);
    return vergleicheMac(drucker.mac, gesehen);
  }

  /// Nur der Verbindungstest wie bis 1.4.2 (`PrinterDriver.status`).
  Future<bool> _nurErreichbar(PrinterConfig drucker) async {
    final PrinterState zustand;
    try {
      zustand = await registry
          .driverFor(drucker)
          .status(timeout: budget)
          .timeout(budget, onTimeout: () => PrinterState.offline);
    } on Object catch (e) {
      _log?.warn('Zustand von ${drucker.id} nicht ermittelbar: $e');
      registry.noteState(drucker.id, PrinterState.offline);
      return false;
    }
    registry.noteState(drucker.id, zustand);
    return zustand == PrinterState.online;
  }

  void _alsStumm(PrinterConfig drucker, DruckerLage lage, DateTime jetzt) {
    lage.alsStummMerken(jetzt);
    _log?.info(
      'Drucker ${drucker.id} antwortet nicht auf DLE EOT – Statustakt nur '
      'mit Verbindungstest.',
    );
  }
}
