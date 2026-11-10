import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../config/store.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import 'belegung.dart';
import 'discovery.dart';
import 'hps.dart';
import 'tid.dart';
import 'warmhalten.dart';

/// Höchstens eine Suche im Hintergrund in diesem Abstand. Die Terminal-Suche
/// klopft das ganze Netz ab (bis 18 s); ein ausgeschaltetes Terminal soll das
/// nicht alle zwei Minuten auslösen.
const Duration terminalSucheAbstand = Duration(minutes: 5);

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
  }) : _bridge = bridge,
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

  final Map<String, Future<TerminalFund?>> _laufend =
      <String, Future<TerminalFund?>>{};
  DateTime? _letzteImHintergrund;

  /// Wie viele Suchen wirklich liefen (Tests).
  int suchen = 0;

  /// Suche im Hintergrund für das gemerkte Terminal (nach drei
  /// Fehlberührungen) – höchstens einmal je [terminalSucheAbstand].
  void imHintergrund() => unawaited(_imHintergrund());

  Future<void> _imHintergrund() async {
    final zuletzt = _letzteImHintergrund;
    if (zuletzt != null &&
        _clock().difference(zuletzt) < terminalSucheAbstand) {
      return;
    }
    final tid = (await store.load()).terminal?.tid;
    if (tid == null) return;
    _letzteImHintergrund = _clock();
    await suche(tid);
  }

  /// Sucht das Terminal [tid]; `null` ohne genau einen bestätigten Treffer,
  /// während eines langen Aufrufs oder abgeschaltet.
  Future<TerminalFund?> suche(String roheTid) async {
    // Das Terminal nimmt die TID nur ohne führende Nullen an.
    final tid = tidNormal(roheTid);
    final schluessel = tid;
    final laufend = _laufend[schluessel];
    if (laufend != null) return laufend;
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
      final ergebnis = await _suche();
      final bestaetigt = <({String host, int port, String? serie})>{};
      for (final treffer in ergebnis.found) {
        // Der Reihe nach, nie gleichzeitig – wie die Kasse.
        if (_belegung.irgendeins) return null;
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
      return _uebernimm(tid, fund.host, fund.port, fund.serie);
    } on Object catch (e) {
      // Ohne Fund bleibt es beim Verhalten von 1.4.2.
      _log?.warn('Terminal-Suche nach $tid gescheitert: $e');
      return null;
    }
  }

  Future<TerminalFund> _uebernimm(
    String tid,
    String host,
    int port,
    String? serie,
  ) async {
    final jetzt = _clock().toUtc();
    String? vorher;
    await store.mutate((config) {
      final alt = config.terminal;
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
