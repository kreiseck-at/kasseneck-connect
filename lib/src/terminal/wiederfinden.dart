import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../config/store.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import '../printers/wiederfinden.dart' show beendenHoechstens;
import 'belegung.dart';
import 'discovery.dart';
import 'hps.dart';
import 'tid.dart';
import 'warmhalten.dart';

/// Abstände der Suchen im Hintergrund, solange das Terminal unerreichbar
/// bleibt: erst 5 min, nach einer Suche ohne Fund 15 min, dann 60 min; nach
/// einem Fund oder wenn es wieder antwortet, wieder 5 min. Die Suche klopft
/// das ganze Netz ab (bis 18 s) – ein Terminal, das aus ist, soll das nicht
/// den ganzen Tag alle paar Minuten auslösen.
const List<Duration> terminalSucheAbstaende = <Duration>[
  Duration(minutes: 5),
  Duration(minutes: 15),
  Duration(minutes: 60),
];

/// Der erste Abstand ([terminalSucheAbstaende]).
const Duration terminalSucheAbstand = Duration(minutes: 5);

/// Gesucht wird im Hintergrund nur, solange eine Kasse offen ist (gültiger
/// Token in diesem Fenster, wie beim Statustakt): nachts und in fremden
/// Netzen klopft Connect kein Netz ab.
const Duration terminalKasseOffenFenster = Duration(minutes: 2);

/// Ereignis: das Terminal ist still unter eine neue Adresse gezogen
/// (`{tid, from, to}`). Für Log und Diagnose; die Kasse zeigt nichts.
const String eventTerminalRelocated = 'terminal.relocated';

/// Sucht Terminals im Netz (wie `discoverTerminals`; Tests ersetzen es).
typedef TerminalSuche = Future<TerminalDiscoveryResult> Function();

/// Ergebnis einer Terminal-Suche nach TID.
class TerminalFund {
  const TerminalFund({
    required this.tid,
    required this.host,
    required this.port,
    required this.vorher,
  });

  final String tid;
  final String host;
  final int port;

  /// Die zuvor gemerkte Adresse (`host:port`), `null` ohne.
  final String? vorher;

  bool get umgezogen => vorher != null && vorher != '$host:$port';
}

/// Findet das Terminal einer TID unter einer neuen Adresse (Spec 1.3).
///
/// Suche wie `terminal/discovery.dart`, danach die Diagnose mit der TID je
/// Treffer (`tidBestaetigt`, dieselbe Regel wie die Kasse). Nur genau ein
/// bestätigter Treffer wird übernommen. Nie während eines langen
/// Terminal-Aufrufs, je TID eine Suche zugleich. Abgeschaltet über
/// `terminal_relocate`.
class TerminalWiederfinder {
  TerminalWiederfinder({
    required this.store,
    required HpsBridge bridge,
    required TerminalSuche suche,
    required TerminalBelegung belegung,
    TerminalWarmhalter? warmhalter,
    EventBus? events,
    AgentLog? log,
    DateTime Function()? clock,
    DateTime? Function()? kasseZuletzt,
  }) : _kasseZuletzt = kasseZuletzt,
       _bridge = bridge,
       _suche = suche,
       _belegung = belegung,
       _warmhalter = warmhalter,
       _events = events,
       _log = log,
       _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final HpsBridge _bridge;
  final TerminalSuche _suche;
  final TerminalBelegung _belegung;
  final TerminalWarmhalter? _warmhalter;
  final EventBus? _events;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Wann zuletzt eine Kasse mit gültigem Token kam; `null`: keine Angabe –
  /// dann gilt die Kasse als offen (Einbettungen ohne Kontext).
  final DateTime? Function()? _kasseZuletzt;

  final Map<String, Future<TerminalFund?>> _laufend =
      <String, Future<TerminalFund?>>{};
  DateTime? _letzteImHintergrund;

  /// Suchen ohne Fund in Folge; bestimmt den Abstand zur nächsten
  /// ([terminalSucheAbstaende]).
  int _ohneFund = 0;

  /// Laufende Anstöße im Hintergrund (Tests, Anhalten).
  final Set<Future<void>> _hintergrund = <Future<void>>{};

  /// Wie viele Suchen wirklich liefen (Tests).
  int suchen = 0;

  bool _beendet = false;

  /// Hält an: keine neuen Suchen, laufende übernehmen nichts mehr; wartet
  /// höchstens `beendenHoechstens` auf sie.
  Future<void> beenden() async {
    _beendet = true;
    try {
      await Future.wait(<Future<Object?>>[
        ..._hintergrund,
        ..._laufend.values,
      ]).timeout(beendenHoechstens);
    } on TimeoutException {
      // Eine Suche, die noch im Netz hängt, schreibt nach dem Ende nichts.
    }
  }

  /// Suche im Hintergrund für das gemerkte Terminal (nach drei
  /// Fehlberührungen und danach weiter) – nur bei offener Kasse und im
  /// wachsenden Abstand [terminalSucheAbstaende].
  void imHintergrund() {
    late final Future<void> lauf;
    lauf = _imHintergrund().whenComplete(() {
      _hintergrund.remove(lauf);
    });
    _hintergrund.add(lauf);
  }

  /// Wartet auf die Anstöße im Hintergrund und die laufenden Suchen.
  Future<void> erledigt() async {
    while (_hintergrund.isNotEmpty || _laufend.isNotEmpty) {
      await Future.wait(<Future<Object?>>[..._hintergrund, ..._laufend.values]);
    }
  }

  /// Das Terminal antwortet wieder: der nächste Ausfall beginnt beim kurzen
  /// Abstand.
  void wiederErreichbar() => _ohneFund = 0;

  /// Ob gerade eine Kasse offen ist.
  bool get _kasseOffen {
    final quelle = _kasseZuletzt;
    if (quelle == null) return true;
    final zuletzt = quelle();
    if (zuletzt == null) return false;
    final alter = _clock().difference(zuletzt);
    return !alter.isNegative && alter <= terminalKasseOffenFenster;
  }

  Future<void> _imHintergrund() async {
    if (!_kasseOffen) return;
    final zuletzt = _letzteImHintergrund;
    if (zuletzt != null) {
      final stufe = (_ohneFund - 1).clamp(0, terminalSucheAbstaende.length - 1);
      final alter = _clock().difference(zuletzt);
      if (!alter.isNegative && alter < terminalSucheAbstaende[stufe]) return;
    }
    final tid = (await store.load()).terminal?.tid;
    if (tid == null) return;
    final arbeit = await _starte(tid);
    // Die Sperrzeit gilt nur nach einer echten Suche: war das Terminal
    // belegt, kommt der nächste Anstoß gleich wieder dran.
    if (arbeit == null) return;
    _letzteImHintergrund = _clock();
    final fund = await arbeit;
    _ohneFund = fund != null ? 0 : _ohneFund + 1;
  }

  /// Sucht das Terminal [tid]; `null` ohne genau einen bestätigten Treffer,
  /// während eines langen Aufrufs oder abgeschaltet.
  Future<TerminalFund?> suche(String roheTid) async {
    final arbeit = await _starte(roheTid);
    return arbeit == null ? null : await arbeit;
  }

  /// Die laufende oder eine eben begonnene Suche nach [roheTid]; `null`, wenn
  /// keine begann (angehalten, abgeschaltet, Terminal belegt).
  Future<Future<TerminalFund?>?> _starte(String roheTid) async {
    // Das Terminal nimmt die TID nur ohne führende Nullen an.
    final tid = tidNormal(roheTid);
    final schluessel = tid;
    final laufend = _laufend[schluessel];
    if (laufend != null) return laufend;
    if (_beendet) return null;
    final config = await store.load();
    if (!config.aktiv(Neuerung.terminalWiederfinden)) return null;
    final inzwischen = _laufend[schluessel];
    if (inzwischen != null) return inzwischen;
    if (_belegung.irgendeins) {
      _log?.info('Terminal-Suche verschoben: ein Terminal-Aufruf läuft.');
      return null;
    }
    suchen++;
    final arbeit = _suchen(tid).whenComplete(() {
      _laufend.remove(schluessel);
    });
    _laufend[schluessel] = arbeit;
    return arbeit;
  }

  Future<TerminalFund?> _suchen(String tid) async {
    try {
      // Welche TID gemerkt war, als die Suche begann: steht beim Übernehmen
      // eine andere da, hat inzwischen jemand ein anderes Terminal
      // eingerichtet (siehe _uebernimm).
      final vorherTid = (await store.load()).terminal?.tid;
      final ergebnis = await _suche();
      final bestaetigt = <({String host, int port, String? serie})>{};
      for (final treffer in ergebnis.found) {
        // Der Reihe nach, nie gleichzeitig – wie die Kasse. Jede Diagnose ist
        // als kurzer Aufruf angemeldet: eine Zahlung, die jetzt beginnt,
        // wartet sie ab, und neben einer Zahlung geht keine hinaus.
        if (_belegung.irgendeins) return null;
        final kurz = _belegung.kurzBeginnen(
          tid: tid,
          host: treffer.host,
          port: treffer.port,
        );
        if (kurz == null) return null;
        try {
          final antwort = await _bridge.diagnosis(
            host: treffer.host,
            port: treffer.port,
            tid: tid,
          );
          if (tidBestaetigt(antwort, tid)) {
            bestaetigt.add((
              host: treffer.host,
              port: treffer.port,
              serie: terminalSerie(antwort),
            ));
          }
        } on HpsWegFehler catch (e) {
          // Nicht erreichbar oder kein HPS: bestätigt nichts.
          _log?.info(
            'Terminal-Suche: ${treffer.host}:${treffer.port} bestätigt $tid '
            'nicht (${e.code}).',
          );
        } finally {
          _belegung.kurzBeenden(kurz);
        }
      }
      if (bestaetigt.length != 1) {
        _log?.info(
          'Terminal $tid: ${bestaetigt.isEmpty ? 'kein' : bestaetigt.length} '
          'bestätigter Treffer – keine Adresse übernommen.',
        );
        return null;
      }
      final fund = bestaetigt.single;
      if (_beendet) return null;
      return _uebernimm(tid, fund.host, fund.port, fund.serie, vorherTid);
    } on Object catch (e) {
      // Ohne Fund bleibt es beim Verhalten von 1.4.2.
      _log?.warn('Terminal-Suche nach $tid gescheitert: $e');
      return null;
    }
  }

  /// Übernimmt [host]:[port] für [tid] – nicht, wenn seit Beginn der Suche
  /// ([vorherTid]) ein Terminal mit einer anderen TID gemerkt wurde: das
  /// ist neuer als dieser Fund (`null`).
  Future<TerminalFund?> _uebernimm(
    String tid,
    String host,
    int port,
    String? serie,
    String? vorherTid,
  ) async {
    final jetzt = _clock().toUtc();
    String? vorher;
    var verdraengt = false;
    await store.mutate((config) {
      final alt = config.terminal;
      final jetztTid = alt?.tid;
      if (jetztTid != null &&
          !gleicheTid(jetztTid, tid) &&
          (vorherTid == null || !gleicheTid(jetztTid, vorherTid))) {
        verdraengt = true;
        return config;
      }
      vorher = alt == null ? null : '${alt.host}:${alt.port}';
      final neu = TerminalConfig(
        kind: alt?.kind ?? 'hobex',
        host: host,
        port: port,
        tid: tid,
        mac: alt != null && alt.host == host ? alt.mac : null,
        confirmedAt: jetzt,
        serial: serie ?? (alt != null && alt.host == host ? alt.serial : null),
        extras: alt?.extras,
      );
      final mitTerminal = config.copyWith(terminal: neu);
      if (vorher == null || vorher == '$host:$port') return mitTerminal;
      return mitTerminal.mitAdressWechsel(
        AdressWechsel(
          at: jetzt,
          art: GeraeteArt.terminal,
          kennung: tid,
          von: vorher!,
          nach: '$host:$port',
        ),
      );
    });
    if (verdraengt) {
      _log?.info(
        'Terminal $tid: inzwischen ist ein anderes Terminal gemerkt – '
        '$host:$port nicht übernommen.',
      );
      return null;
    }
    final fund = TerminalFund(tid: tid, host: host, port: port, vorher: vorher);
    _warmhalter?.merken(host, port, tid: tid, bestaetigt: true, serie: serie);
    if (fund.umgezogen) {
      _log?.info(
        'Terminal $tid: Adresse ${fund.vorher} → $host:$port, TID bestätigt',
      );
      _events?.publish(eventTerminalRelocated, <String, Object?>{
        'tid': tid,
        'from': fund.vorher,
        'to': '$host:$port',
      });
    }
    return fund;
  }
}
