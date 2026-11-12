import 'dart:async';
import 'dart:math';

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

/// Zufälliger Zuschlag auf jeden Abstand des Takts, als Anteil davon (ein
/// Viertel: 60 bis 75 s). Zwei Connect, die zur selben Zeit starten (zwei
/// Benutzer an einem Rechner, ein Neustart nach einem Stromausfall), fragen
/// denselben Drucker so nicht dauerhaft im selben Augenblick – er bedient nur
/// eine Verbindung zugleich, und die andere bliebe jedes Mal stumm.
const int taktStreuungTeiler = 4;

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
///
/// Eine Abfrage ist kurz: eine Verbindung, ein Antwortfenster von
/// [bereitFrist] (ein bereiter Drucker antwortet, sobald er die Verbindung
/// bedient, in Millisekunden). Schweigt ein Drucker, fragt Connect nicht
/// eigens nach – Schweigen hält keinen Bon auf, und jede Nachfrage hielte
/// einen Drucker, der nur eine Verbindung zugleich bedient, für andere
/// Rechner besetzt (Gerätetest 12.11.2026: zwei Connect, die einander alle
/// 5 s nachfragten, hielten den TM-T20III minutenlang stumm). Der nächste
/// Takt, der nächste Bon oder eine Abfrage auf Zuruf sehen, wann er wieder
/// antwortet.
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
    Duration? streuung,
    Random? random,
    this.budget = statusAbrufBudget,
  }) : streuung = streuung ?? abstand ~/ taktStreuungTeiler,
       _random = random ?? Random(),
       _abfrage = abfrage,
       _arp = arp,
       _schnittstellen = schnittstellen,
       _kasseZuletzt = kasseZuletzt,
       _log = log,
       _clock = clock ?? DateTime.now;

  final PrinterRegistry registry;
  final PrintQueue queue;
  final EscPosAbfrage _abfrage;

  /// ARP-Tabelle und Schnittstellen für den MAC-Vergleich: hängt unter der
  /// Adresse nachweislich ein anderes Gerät (andere MAC), zeigt sein
  /// Schweigen keinen Hinweis. Ohne sie ist die MAC unbekannt.
  final ArpTabelle? _arp;
  final InterfaceProbe? _schnittstellen;
  final DateTime? Function() _kasseZuletzt;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Wird gerufen, wenn der Takt einen Drucker [verfehltBisSuche]-mal
  /// hintereinander nicht sah (die gründliche Suche hängt sich hier an).
  void Function(String printerId)? beiDauerndVerfehlt;

  /// Erkennt einen Drucker auf Zuruf (Kennungspflege); `null`: nie.
  Future<void> Function(String printerId)? erkennen;

  /// Grundabstand des Takts.
  final Duration abstand;

  /// Höchster zufälliger Zuschlag je Abstand ([taktStreuungTeiler]).
  final Duration streuung;

  final Random _random;
  final Duration budget;

  Timer? _timer;
  Future<void>? _runde;

  /// Ob der Dienst läuft (zwischen [start] und [stop]).
  bool _laeuft = false;

  /// Wie viele Runden der Takt gedreht hat (Tests).
  int runden = 0;

  /// Startet den Takt (einmal je Agent).
  void start() {
    if (_laeuft) return;
    _laeuft = true;
    _planeRunde();
  }

  /// Abstand bis zur nächsten Runde: [abstand] plus ein zufälliger Teil von
  /// [streuung].
  Duration naechsterAbstand() {
    final streu = min(streuung.inMilliseconds, 1 << 31);
    return streu <= 0
        ? abstand
        : abstand + Duration(milliseconds: _random.nextInt(streu));
  }

  void _planeRunde() {
    _timer = Timer(naechsterAbstand(), () {
      unawaited(
        runde().whenComplete(() {
          if (_laeuft) _planeRunde();
        }),
      );
    });
  }

  /// Hält den Takt an und wartet eine laufende Runde ab.
  Future<void> stop() async {
    _laeuft = false;
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
        // Nur bewiesene Modelle: jeder andere Drucker sieht von Connect außer
        // den Bons nichts, wie bis 1.4.2.
        config.printers.where(registry.pruefbar).map((drucker) async {
          // Ein Bon aus diesem Prozess druckt womöglich noch: der Drucker war
          // eben erreichbar, und eine Abfrage jetzt bewiese nichts.
          if (registry.lagen.vorhanden(drucker.id)?.druckt(jetzt) ?? false) {
            _zaehle(drucker.id, true);
            return;
          }
          final erreichbar = await queue.exclusive(drucker.id, () async {
            // Ein eigener Bon stand vor dieser Runde in der Warteschlange und
            // druckt jetzt womöglich noch: keine Abfrage.
            final lage = registry.lagen.vorhanden(drucker.id);
            if (lage?.druckt(_clock()) ?? false) return true;
            return _abfragen(drucker, config);
          });
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
  ///
  /// Auf Zuruf darf Connect den Drucker auch erkennen ([erkennen]), wenn sein
  /// Modell noch nicht über `GS I 67` feststeht. Papier und Deckel fragt es
  /// nur bei einem bewiesenen Modell; sonst nur die Erreichbarkeit wie 1.4.2.
  Future<Map<String, Object?>?> jetzt(String id) async {
    var drucker = await registry.find(id);
    if (drucker == null) return null;
    final erkenne = erkennen;
    if (erkenne != null &&
        drucker.kind == PrinterKind.tcp9100 &&
        drucker.modelSource != KennungsQuelle.escpos) {
      await erkenne(id);
      drucker = await registry.find(id) ?? drucker;
    }
    final config = await registry.store.load();
    final gefunden = drucker;
    await queue.exclusive<void>(id, () async {
      if (registry.pruefbar(gefunden)) {
        await _abfragen(gefunden, config);
      } else {
        await _nurErreichbar(gefunden);
      }
    });
    return registry.zusammenfassung(gefunden);
  }

  /// Eine Abfrage: ob das Gerät erreichbar war. Wirft nie.
  Future<bool> _abfragen(PrinterConfig drucker, AgentConfig config) async {
    final jetzt = _clock();
    final lage = registry.lagen.von(drucker.id);
    if (!config.aktiv(Neuerung.druckerStatus)) {
      return _nurErreichbar(drucker);
    }

    switch (drucker.kind) {
      case PrinterKind.tcp9100:
        final statusfaehig = drucker.statusCapableAt != null;
        // Ein stummes Gerät, das nie geantwortet hat, bekommt keine Abfrage,
        // nur den Verbindungstest wie bis 1.4.2.
        if (!statusfaehig && lage.stumm(jetzt)) {
          return _nurErreichbar(drucker);
        }
        // Ein Versuch. Ein Drucker, der schon geantwortet hat, bekommt
        // [bereitFrist]: er bedient eine neue Verbindung erst rund 0,5 s nach
        // dem Ende der vorigen. Schweigen ist ohnehin nur ein Hinweis.
        final antworten = await _abfrage.frage(
          drucker.host,
          drucker.port,
          fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
          budget: budget,
          handshake: statusfaehig ? bereitFrist : handshakeFrist,
        );
        if (!antworten.verbunden) {
          // Abgelehnt direkt nach einer eigenen Verbindung: der Drucker gibt
          // langsam frei, er ist nicht weg – ab jetzt kein Takt mehr für ihn.
          if (antworten.verbindungsFehler != null && lage.ebenVerbunden()) {
            lage.gibtLangsamFrei = true;
            _log?.info(
              'Drucker ${drucker.id} gibt seine Verbindung erst verzögert '
              'frei – keine Abfrage mehr im Takt und vor dem Bon.',
            );
            return true;
          }
          registry.noteState(drucker.id, PrinterState.offline);
          return false;
        }
        lage.abgefragt();
        registry.noteState(drucker.id, PrinterState.online);
        final mac = await _macVergleich(drucker);
        if (antworten.stumm && !statusfaehig) {
          if (!lage.druckt(jetzt)) _alsStumm(drucker, lage, jetzt);
          return true;
        }
        if (statusfaehig && antworten.offlineGrund == null) {
          // Keine gültige Antwort: nur ein Hinweis, nie „nicht bereit“. Die
          // erste in Folge ändert nichts, und während eines eigenen Bons
          // zählt sie nicht.
          if (lage.druckt(jetzt)) return true;
          lage.ohneAntwort();
          final zustand = zustandOhneAntwort(lage, mac);
          if (zustand != null) registry.noteZustand(drucker.id, zustand, jetzt);
          return true;
        }
        if (antworten.offlineGrund != null) lage.antwortet();
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
        // Kein ePOS-Modell ist bewiesen (das Modell kommt nie über GS I 67).
        return _nurErreichbar(drucker);
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
  ///
  /// Stand eben eine eigene Abfrage-Verbindung (etwa die Erkennung auf
  /// Zuruf) und lehnt der Drucker jetzt ab, gibt er nur sie noch nicht frei:
  /// dieselbe Adresse noch einmal, alle [freigabeSchritt], bis
  /// [freigabeFenster] seit der Abfrage um ist. Ohne die Abfrage hätte
  /// 1.4.2 ihn erreicht.
  Future<bool> _nurErreichbar(PrinterConfig drucker) async {
    final lage = registry.lagen.von(drucker.id);
    while (true) {
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
      if (zustand != PrinterState.online && lage.ebenAbgefragt()) {
        await Future<void>.delayed(freigabeSchritt);
        continue;
      }
      if (zustand == PrinterState.online) lage.abgefragt();
      registry.noteState(drucker.id, zustand);
      return zustand == PrinterState.online;
    }
  }

  void _alsStumm(PrinterConfig drucker, DruckerLage lage, DateTime jetzt) {
    lage.alsStummMerken(jetzt);
    _log?.info(
      'Drucker ${drucker.id} antwortet nicht auf DLE EOT – Statustakt nur '
      'mit Verbindungstest.',
    );
  }
}
