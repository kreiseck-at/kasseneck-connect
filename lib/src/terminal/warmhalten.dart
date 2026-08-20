import 'dart:async';

import '../config/model.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../printers/discovery.dart' show TcpProbe, tcpReachable;
import 'hps.dart';

/// Abstand der Wachhalte-Berührungen.
///
/// Android-Terminals legen das WLAN im Ruhezustand schlafen; nach ein paar
/// Minuten Stille beantworten sie minutenlang gar nichts mehr (belegt am
/// Gerät: 33 % Paketverlust, Suche und Diagnose liefen ins Leere, nach dem
/// Aufwecken 80 ms Antwortzeit). 45 s liegen sicher unter jeder Doze-Schwelle.
const Duration warmhalteIntervall = Duration(seconds: 45);

/// Zeitlimit einer einzelnen Berührung (nur TCP-Verbindungsaufbau).
const Duration warmhalteTimeout = Duration(seconds: 3);

/// Haelt das Kassen-Terminal wach: eine kurze TCP-Beruehrung alle 45 s,
/// solange der Agent laeuft. Keine Daten, keine Zahlung — nur der
/// Verbindungsaufbau, der das Funkmodul am Einschlafen hindert.
///
/// Das Ziel merkt sich der Agent beim ERSTEN erfolgreichen Terminal-Kontakt
/// (Suche, Test, Zahlung) und schreibt es in die Konfiguration — nach einem
/// Neustart geht das Wachhalten von selbst weiter.
class TerminalWarmhalter {
  TerminalWarmhalter({
    required this.store,
    required this.log,
    this.intervall = warmhalteIntervall,
    TcpProbe probe = tcpReachable,
  }) : _probe = probe;

  final ConfigStore store;
  final AgentLog log;
  final Duration intervall;
  final TcpProbe _probe;

  Timer? _timer;
  String? _host;
  int _port = hpsDefaultPort;
  bool _zuletztErreichbar = true;

  /// Anzahl der Beruehrungen (Tests).
  int beruehrungen = 0;

  /// Aus der gespeicherten Konfiguration starten (Agentenstart).
  void startAus(AgentConfig config) {
    final t = config.terminal;
    if (t == null) return;
    _starten(t.host, t.port, persistieren: false);
  }

  /// Ein Terminal hat geantwortet: Ziel merken (und persistieren), Timer an.
  void merken(String host, int port) {
    if (_host == host && _port == port && _timer != null) return;
    _starten(host, port, persistieren: true);
  }

  void _starten(String host, int port, {required bool persistieren}) {
    _host = host;
    _port = port;
    _timer?.cancel();
    _timer = Timer.periodic(intervall, (_) => _beruehren());
    log.info(
      'Terminal-Wachhalten an: $host:$port (alle ${intervall.inSeconds} s).',
    );
    if (persistieren) {
      // Fire-and-forget: das Wachhalten haengt nicht am Plattenschreiben.
      unawaited(
        store.mutate(
          (c) => c.copyWith(
            terminal: TerminalConfig(host: host, port: port),
          ),
        ),
      );
    }
  }

  Future<void> _beruehren() async {
    final host = _host;
    if (host == null) return;
    beruehrungen += 1;
    final erreichbar = await _probe(host, _port, warmhalteTimeout);
    // Nur Zustandswechsel loggen — sonst waechst das Log um 1920 Zeilen/Tag.
    if (erreichbar != _zuletztErreichbar) {
      log.info(
        erreichbar
            ? 'Terminal $host:$_port wieder erreichbar.'
            : 'Terminal $host:$_port antwortet nicht (Wachhalte-Beruehrung).',
      );
      _zuletztErreichbar = erreichbar;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
