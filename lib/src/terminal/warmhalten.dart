import 'dart:async';

import '../config/model.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../printers/discovery.dart' show TcpProbe, tcpReachable;
import 'belegung.dart';
import 'hps.dart';
import 'tid.dart';

/// Abstand der Wachhalte-Berührungen.
///
/// Android-Terminals legen das WLAN im Ruhezustand schlafen; nach ein paar
/// Minuten Stille beantworten sie minutenlang gar nichts mehr (belegt am
/// Gerät: 33 % Paketverlust, Suche und Diagnose liefen ins Leere, nach dem
/// Aufwecken 80 ms Antwortzeit). 45 s liegen sicher unter jeder Doze-Schwelle.
const Duration warmhalteIntervall = Duration(seconds: 45);

/// Zeitlimit einer einzelnen Berührung (nur TCP-Verbindungsaufbau).
const Duration warmhalteTimeout = Duration(seconds: 3);

/// So oft hintereinander darf eine Berührung scheitern, bevor Connect das
/// Terminal sucht (Spec 1.3: dreimal, rund zwei Minuten). Ein kurzer
/// WLAN-Schlaf des Terminals löst so keine Suche aus.
const int fehlberuehrungenBisSuche = 3;

/// Eine Bestätigung derselben TID unter derselben Adresse wird höchstens so
/// oft geschrieben: jede Zahlung bestätigt neu, die `config.json` soll nicht
/// bei jedem Gast geschrieben werden. Gemessen an [umleitungHoechstalter]
/// (ein Tag) ist eine Viertelstunde genau genug.
const Duration bestaetigungAuffrischen = Duration(minutes: 15);

/// Liest die MAC einer Adresse (ARP, nur im selben Netz); `null` unbekannt.
typedef MacLeser = Future<String?> Function(String host);

/// Haelt das Kassen-Terminal wach: eine kurze TCP-Beruehrung alle 45 s,
/// solange der Agent laeuft. Keine Daten, keine Zahlung — nur der
/// Verbindungsaufbau, der das Funkmodul am Einschlafen hindert.
///
/// Das Ziel merkt sich der Agent beim ERSTEN erfolgreichen Terminal-Kontakt
/// (Suche, Test, Zahlung) und schreibt es in die Konfiguration — nach einem
/// Neustart geht das Wachhalten von selbst weiter. Ab 1.5.0 samt TID und dem
/// Zeitpunkt, zu dem eine Antwort des Terminals sie unter dieser Adresse
/// bestätigt hat; nur eine solche Adresse darf Ziel einer Umleitung sein.
class TerminalWarmhalter {
  TerminalWarmhalter({
    required this.store,
    required this.log,
    this.intervall = warmhalteIntervall,
    TcpProbe probe = tcpReachable,
    TerminalBelegung? belegung,
    MacLeser? macLesen,
    DateTime Function()? clock,
  }) : _probe = probe,
       _belegung = belegung,
       _macLesen = macLesen,
       _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final AgentLog log;
  final Duration intervall;
  final TcpProbe _probe;
  final TerminalBelegung? _belegung;
  final MacLeser? _macLesen;
  final DateTime Function() _clock;

  /// Wird gerufen, wenn das Terminal [fehlberuehrungenBisSuche]-mal
  /// hintereinander nicht antwortete (die Suche hängt sich hier an).
  void Function()? beiDauerndUnerreichbar;

  Timer? _timer;
  String? _host;
  int _port = hpsDefaultPort;
  bool _zuletztErreichbar = true;
  int _fehlInFolge = 0;

  /// Zuletzt bestätigte TID und wann (im Speicher, um Schreiben zu sparen).
  String? _tid;
  DateTime? _bestaetigtAm;

  /// Ergebnis der letzten Berührung (`null`: noch keine) und wann.
  bool? erreichbar;
  DateTime? geprueftAm;

  /// Anzahl der Beruehrungen (Tests).
  int beruehrungen = 0;

  /// Das zuletzt angestoßene Speichern (Agent hält an, Tests).
  Future<void> erledigt = Future<void>.value();

  /// Aus der gespeicherten Konfiguration starten (Agentenstart).
  void startAus(AgentConfig config) {
    final t = config.terminal;
    if (t == null) return;
    _tid = t.tid;
    _bestaetigtAm = t.confirmedAt;
    _starten(t.host, t.port);
  }

  /// Ein Terminal hat geantwortet: Ziel merken (und persistieren), Timer an.
  ///
  /// [tid] mit [bestaetigt] heißt: die Antwort hat diese TID unter dieser
  /// Adresse bestätigt (`tidBestaetigt`).
  void merken(
    String host,
    int port, {
    String? tid,
    bool bestaetigt = false,
    String? serie,
  }) {
    final jetzt = _clock();
    final adresseNeu = _host != host || _port != port || _timer == null;
    final zuletzt = _bestaetigtAm;
    final auffrischen =
        bestaetigt &&
        tid != null &&
        (adresseNeu ||
            _tid == null ||
            !gleicheTid(_tid!, tid) ||
            zuletzt == null ||
            jetzt.difference(zuletzt) >= bestaetigungAuffrischen);
    if (!adresseNeu && !auffrischen) return;
    if (adresseNeu) _starten(host, port);
    if (auffrischen) {
      _tid = tid;
      _bestaetigtAm = jetzt;
    } else {
      // Neue Adresse ohne Bestätigung: was über die alte bestätigt war, gilt
      // hier nicht.
      _bestaetigtAm = null;
    }
    // Fire-and-forget: das Wachhalten haengt nicht am Plattenschreiben.
    erledigt = _speichern(
      host,
      port,
      tid: auffrischen ? tid : null,
      serie: auffrischen ? serie : null,
      am: jetzt,
    );
  }

  Future<void> _speichern(
    String host,
    int port, {
    required String? tid,
    required String? serie,
    required DateTime am,
  }) async {
    try {
      final mac = tid == null ? null : await _macLesen?.call(host);
      await store.mutate((c) {
        final alt = c.terminal;
        final gleicheAdresse =
            alt != null && alt.host == host && alt.port == port;
        return c.copyWith(
          terminal: TerminalConfig(
            kind: alt?.kind ?? 'hobex',
            host: host,
            port: port,
            tid: tid ?? (gleicheAdresse ? alt.tid : null),
            mac: normalizeMac(mac) ?? (gleicheAdresse ? alt.mac : null),
            confirmedAt: tid != null
                ? am.toUtc()
                : (gleicheAdresse ? alt.confirmedAt : null),
            serial: serie ?? (gleicheAdresse ? alt.serial : null),
            extras: alt?.extras,
          ),
        );
      });
    } on Object catch (e) {
      // Ohne gespeichertes Ziel hält das Wachhalten trotzdem wach; nur die
      // Umleitung nach einem Neustart fehlt dann.
      log.warn('Terminal-Ziel ließ sich nicht speichern: $e');
    }
  }

  void _starten(String host, int port) {
    _host = host;
    _port = port;
    _fehlInFolge = 0;
    _timer?.cancel();
    _timer = Timer.periodic(intervall, (_) => _beruehren());
    log.info(
      'Terminal-Wachhalten an: $host:$port (alle ${intervall.inSeconds} s).',
    );
  }

  Future<void> _beruehren() async {
    final host = _host;
    if (host == null) return;
    // Während einer Zahlung hält die Zahlung selbst das Terminal wach; eine
    // zweite Verbindung neben ihr braucht es nicht.
    if (_belegung?.belegt(tid: _tid, host: host, port: _port) ?? false) {
      return;
    }
    beruehrungen += 1;
    final ergebnis = await _probe(host, _port, warmhalteTimeout);
    erreichbar = ergebnis;
    geprueftAm = _clock();
    // Nur Zustandswechsel loggen — sonst waechst das Log um 1920 Zeilen/Tag.
    if (ergebnis != _zuletztErreichbar) {
      log.info(
        ergebnis
            ? 'Terminal $host:$_port wieder erreichbar.'
            : 'Terminal $host:$_port antwortet nicht (Wachhalte-Beruehrung).',
      );
      _zuletztErreichbar = ergebnis;
    }
    if (ergebnis) {
      _fehlInFolge = 0;
      return;
    }
    _fehlInFolge++;
    if (_fehlInFolge == fehlberuehrungenBisSuche) {
      beiDauerndUnerreichbar?.call();
    }
  }

  /// Das Feld `terminal` der Langform von `GET /v1/status`; `null` ohne
  /// gemerktes Terminal.
  Map<String, Object?>? statusFeld(TerminalConfig? gemerkt) {
    if (gemerkt == null) return null;
    return <String, Object?>{
      'tid': gemerkt.tid,
      'host': gemerkt.host,
      'port': gemerkt.port,
      'reachable': erreichbar,
      'checkedAt': geprueftAm?.toUtc().toIso8601String(),
      'confirmedAt': gemerkt.confirmedAt?.toUtc().toIso8601String(),
      if (gemerkt.serial != null) 'serial': gemerkt.serial,
    };
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
