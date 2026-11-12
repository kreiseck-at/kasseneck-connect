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
    this.nachfrageAbstand = schweigenNachfrageAbstand,
    this.nachfrageFrist = bereitFrist,
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

  /// Erkennt einen Drucker auf Zuruf (Kennungspflege); `null`: nie.
  Future<void> Function(String printerId)? erkennen;

  final Duration abstand;
  final Duration budget;

  /// Abstand der Nachfragen, solange ein statusfähiger Drucker schweigt
  /// ([schweigenNachfrageAbstand]; Tests geben weniger vor).
  final Duration nachfrageAbstand;

  /// Antwortfenster einer Nachfrage ([bereitFrist]; Tests geben weniger vor).
  final Duration nachfrageFrist;

  Timer? _timer;
  Future<void>? _runde;

  /// Ob der Dienst läuft (zwischen [start] und [stop]): nur dann plant er
  /// Nachfragen von selbst.
  bool _laeuft = false;

  /// Drucker, deren Schweigen gerade verfolgt wird, mit der nächsten
  /// geplanten Nachfrage (`null`, während eine läuft).
  final Map<String, Timer?> _verfolgt = <String, Timer?>{};

  /// Laufende Nachfragen ([stop] wartet auf sie).
  final Set<Future<void>> _nachfragen = <Future<void>>{};

  /// Wie viele Runden der Takt gedreht hat (Tests).
  int runden = 0;

  /// Wie viele Nachfragen wirklich gefragt haben (Tests).
  int nachfragen = 0;

  /// Startet den Takt (einmal je Agent).
  void start() {
    _laeuft = true;
    _timer ??= Timer.periodic(abstand, (_) => unawaited(runde()));
  }

  /// Hält den Takt und die Nachfragen an und wartet laufende ab.
  Future<void> stop() async {
    _laeuft = false;
    _timer?.cancel();
    _timer = null;
    for (final timer in _verfolgt.values) {
      timer?.cancel();
    }
    _verfolgt.clear();
    await _runde;
    while (_nachfragen.isNotEmpty) {
      await Future.wait(_nachfragen.toList());
    }
  }

  /// Ob das Schweigen von [id] gerade verfolgt wird.
  bool verfolgt(String id) => _verfolgt.containsKey(id);

  /// Ein statusfähiger Drucker schweigt: ab jetzt alle [nachfrageAbstand]
  /// eine Nachfrage über seine Warteschlange, bis er antwortet, nicht mehr
  /// erreichbar ist, die Kasse zu ist oder der Dienst anhält. Erst so ist
  /// Schweigen lückenlos beobachtet (siehe [schweigenLuecke]); zwei
  /// Stichproben im Abstand des Takts heißen nie „nicht bereit“.
  ///
  /// Nur bei laufendem Dienst; ein zweiter Anstoß für denselben Drucker
  /// ändert nichts.
  void schweigenVerfolgen(String id) {
    if (!_laeuft || _verfolgt.containsKey(id)) return;
    _planeNachfrage(id);
  }

  void _planeNachfrage(String id) {
    _verfolgt[id] = Timer(nachfrageAbstand, () {
      _verfolgt[id] = null;
      late final Future<void> lauf;
      lauf = nachfrage(id)
          .then((weiter) {
            if (weiter && _laeuft && _verfolgt.containsKey(id)) {
              _planeNachfrage(id);
            } else {
              _verfolgt.remove(id);
            }
          })
          .catchError((Object e) {
            _verfolgt.remove(id);
            _log?.warn('Nachfrage bei $id: $e');
          })
          .whenComplete(() {
            // Block statt Pfeil: `remove` liefert einen Wahrheitswert.
            _nachfragen.remove(lauf);
          });
      _nachfragen.add(lauf);
    });
  }

  /// Eine Nachfrage bei [id], solange er schweigt; `true`, wenn er weiter
  /// schweigt (oder der eigene Bon noch druckt) und die nächste folgen soll.
  ///
  /// Nur ein bewiesenes, statusfähiges Modell, nur bei offener Kasse und
  /// eingeschalteten `printer_status` und `status_poll`; nie neben einem
  /// eigenen Bon (Warteschlange) und nicht, solange er druckt. Ein Versuch
  /// mit `bereitFrist` – die Nachfragen kommen ohnehin dicht. Nie an ein
  /// Gerät mit nachweislich anderer MAC. Eine abgelehnte Nachfrage (etwa
  /// weil ein anderer Rechner gerade druckt oder fragt) beendet sie, ohne den
  /// Drucker als nicht erreichbar zu melden. Wirft nie.
  Future<bool> nachfrage(String id) async {
    try {
      final config = await registry.store.load();
      if (!config.aktiv(Neuerung.druckerStatus) ||
          !config.aktiv(Neuerung.statusTakt) ||
          !kasseOffen) {
        return false;
      }
      PrinterConfig? drucker;
      for (final eintrag in config.printers) {
        if (eintrag.id == id) drucker = eintrag;
      }
      final lage = registry.lagen.vorhanden(id);
      if (drucker == null ||
          drucker.kind != PrinterKind.tcp9100 ||
          drucker.statusCapableAt == null ||
          !registry.pruefbar(drucker) ||
          lage == null ||
          lage.ohneAntwortInFolge == 0) {
        return false;
      }
      final gefunden = drucker;
      // Steht unter der Adresse nachweislich ein anderes Gerät (andere MAC),
      // bekommt es keine Bytes – die Nachfrage endet.
      if (await _macVergleich(gefunden) == MacVergleich.anders) return false;
      return await queue.exclusive(id, () async {
        // Ein eigener Bon kam dazwischen: er druckt noch, Schweigen bewiese
        // nichts. Weiter verfolgen – die Strecke beginnt danach neu.
        if (lage.druckt(_clock())) return true;
        nachfragen++;
        final ergebnis = await _abfragen(gefunden, config, einVersuch: true);
        return ergebnis.schweigt;
      });
    } on Object catch (e) {
      _log?.warn('Nachfrage bei $id: $e');
      return false;
    }
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
          final ergebnis = await queue.exclusive(
            drucker.id,
            () => _abfragen(drucker, config),
          );
          _zaehle(drucker.id, ergebnis.erreichbar);
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

  /// Eine Abfrage: ob das Gerät erreichbar war und ob es nachweislich
  /// geschwiegen hat (statusfähig, kein eigener Bon druckt). Mit
  /// [einVersuch] nur ein Versuch mit `bereitFrist` (Nachfrage). Wirft nie.
  Future<({bool erreichbar, bool schweigt})> _abfragen(
    PrinterConfig drucker,
    AgentConfig config, {
    bool einVersuch = false,
  }) async {
    final jetzt = _clock();
    final lage = registry.lagen.von(drucker.id);
    if (!config.aktiv(Neuerung.druckerStatus)) {
      return (erreichbar: await _nurErreichbar(drucker), schweigt: false);
    }

    switch (drucker.kind) {
      case PrinterKind.tcp9100:
        final statusfaehig = drucker.statusCapableAt != null;
        // Ein stummes Gerät, das nie geantwortet hat, bekommt keine Abfrage,
        // nur den Verbindungstest wie bis 1.4.2.
        if (!statusfaehig && lage.stumm(jetzt)) {
          return (erreichbar: await _nurErreichbar(drucker), schweigt: false);
        }
        const fragen = <EscPosFrage>{EscPosFrage.rollensensor};
        final antworten = !statusfaehig
            ? await _abfrage.frage(
                drucker.host,
                drucker.port,
                fragen: fragen,
                budget: budget,
              )
            : einVersuch
            ? await _abfrage.frage(
                drucker.host,
                drucker.port,
                fragen: fragen,
                budget: budget,
                handshake: nachfrageFrist,
              )
            : await _abfrage.frageBereit(
                drucker.host,
                drucker.port,
                fragen: fragen,
                budget: budget,
              );
        if (!antworten.verbunden && einVersuch) {
          // Nachfrage ohne Verbindung: nichts beobachtet. Der Takt und der
          // nächste Bon entscheiden über Erreichbarkeit und Freigabe.
          return (erreichbar: true, schweigt: false);
        }
        if (!antworten.verbunden) {
          // Abgelehnt direkt nach einer eigenen Verbindung: der Drucker gibt
          // langsam frei, er ist nicht weg – ab jetzt kein Takt mehr für ihn.
          if (antworten.verbindungsFehler != null && lage.ebenVerbunden()) {
            lage.gibtLangsamFrei = true;
            _log?.info(
              'Drucker ${drucker.id} gibt seine Verbindung erst verzögert '
              'frei – keine Abfrage mehr im Takt und vor dem Bon.',
            );
            return (erreichbar: true, schweigt: false);
          }
          registry.noteState(drucker.id, PrinterState.offline);
          return (erreichbar: false, schweigt: false);
        }
        lage.abgefragt();
        registry.noteState(drucker.id, PrinterState.online);
        final mac = await _macVergleich(drucker);
        if (antworten.stumm && !statusfaehig) {
          if (!lage.druckt(jetzt)) _alsStumm(drucker, lage, jetzt);
          return (erreichbar: true, schweigt: false);
        }
        if (statusfaehig && antworten.offlineGrund == null) {
          // Keine gültige Antwort: nur ein Hinweis, nie „nicht bereit“. Die
          // erste in Folge ändert nichts, und während eines eigenen Bons
          // zählt sie nicht.
          if (lage.druckt(jetzt)) return (erreichbar: true, schweigt: false);
          lage.ohneAntwort();
          // Nachgefragt wird nie bei einem nachweislich anderen Gerät.
          final verfolgen = mac != MacVergleich.anders;
          if (verfolgen) schweigenVerfolgen(drucker.id);
          final zustand = zustandOhneAntwort(lage, mac);
          if (zustand != null) registry.noteZustand(drucker.id, zustand, jetzt);
          return (erreichbar: true, schweigt: verfolgen);
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
        return (erreichbar: true, schweigt: false);
      case PrinterKind.epos:
        // Kein ePOS-Modell ist bewiesen (das Modell kommt nie über GS I 67).
        return (erreichbar: await _nurErreichbar(drucker), schweigt: false);
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
