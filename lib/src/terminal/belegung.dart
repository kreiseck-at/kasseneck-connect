import 'tid.dart';

/// Längste Zeit, die ein langer Terminal-Aufruf als belegt gilt: Zahlung
/// (`hpsZahlungTimeout`, 4 min) plus Verbindungsaufbau und Puffer. Endet ein
/// Aufruf nie sauber (Fehler im Agenten), läuft die Belegung so trotzdem ab –
/// eine Sperre darf nie für immer bleiben.
const Duration belegungHoechstdauer = Duration(minutes: 5);

/// Art eines langen Terminal-Aufrufs.
enum LangerAufruf { zahlung, gutschrift, aufhebung }

/// Ein belegtes Terminal (solange [TerminalBelegung.freigeben] nicht kam).
class TerminalBeleg {
  TerminalBeleg._(this.tid, this.host, this.port, this.art, this.seit);

  final String tid;
  final String host;
  final int port;
  final LangerAufruf art;
  final DateTime seit;
}

/// Wer gerade einen langen Aufruf an welches Terminal hält – prozessweit,
/// für alle Kassen und Tabs zusammen.
///
/// Solange ein Terminal belegt ist, geht kein zweiter langer Aufruf und keine
/// Diagnose dorthin; die Route antwortet sofort `terminal_busy` (nachweislich
/// nichts gesendet). Abbruch und Statusabfrage der laufenden Zahlung bleiben
/// frei – genau sie braucht die Kasse während einer Zahlung.
class TerminalBelegung {
  TerminalBelegung({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<TerminalBeleg> _belege = <TerminalBeleg>[];

  /// Belegt das Terminal [tid] unter [host]:[port]; `null`, wenn es schon
  /// belegt ist (gleiche TID oder gleiche Adresse).
  TerminalBeleg? belegen({
    required String tid,
    required String host,
    required int port,
    required LangerAufruf art,
  }) {
    if (belegt(tid: tid, host: host, port: port)) return null;
    final beleg = TerminalBeleg._(tid, host, port, art, _clock());
    _belege.add(beleg);
    return beleg;
  }

  /// Gibt [beleg] frei; ein zweites Freigeben schadet nicht.
  void freigeben(TerminalBeleg beleg) => _belege.remove(beleg);

  /// Ob ein Terminal mit [tid] oder unter [host]:[port] belegt ist.
  bool belegt({String? tid, String? host, int? port}) {
    _abgelaufeneVergessen();
    return _belege.any(
      (b) =>
          (tid != null && tid.isNotEmpty && gleicheTid(b.tid, tid)) ||
          (host != null && b.host == host && (port == null || b.port == port)),
    );
  }

  /// Ob irgendein langer Aufruf läuft (Suche im Netz wartet dann).
  bool get irgendeins {
    _abgelaufeneVergessen();
    return _belege.isNotEmpty;
  }

  void _abgelaufeneVergessen() {
    final jetzt = _clock();
    _belege.removeWhere((b) => jetzt.difference(b.seit) > belegungHoechstdauer);
  }
}
