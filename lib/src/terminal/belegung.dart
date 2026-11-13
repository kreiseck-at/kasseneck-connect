import 'dart:async';

import 'tid.dart';

/// Längste Zeit, die ein langer Terminal-Aufruf als belegt gilt: Zahlung
/// (`hpsZahlungTimeout`, 4 min) plus Verbindungsaufbau und Puffer. Endet ein
/// Aufruf nie sauber (Fehler im Agenten), läuft die Belegung so trotzdem ab –
/// eine Sperre darf nie für immer bleiben.
const Duration belegungHoechstdauer = Duration(minutes: 5);

/// So lange wartet ein langer Aufruf höchstens auf kurze Aufrufe, die schon
/// unterwegs waren, bevor er begann. Gerätetest HPS 1.14.4: Diagnose und
/// Probe antworten in 0,1–0,25 s; länger hält eine Diagnose eine Zahlung nie
/// auf – danach geht die Zahlung in jedem Fall.
const Duration kurzeAbwartenHoechstens = Duration(seconds: 2);

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

/// Ein kurzer Aufruf (Diagnose, Test) unterwegs zum Terminal.
class KurzerAufruf {
  KurzerAufruf._(this.tid, this.host, this.port);

  final String? tid;
  final String host;
  final int port;
  final Completer<void> _fertig = Completer<void>();
}

/// Wer gerade einen langen Aufruf an welches Terminal hält – prozessweit,
/// für alle Kassen und Tabs zusammen.
///
/// Solange ein Terminal belegt ist, geht kein zweiter langer Aufruf und keine
/// Diagnose dorthin; die Route antwortet sofort `terminal_busy` (nachweislich
/// nichts gesendet). Kurze Aufrufe, die schon unterwegs waren, wartet ein
/// langer höchstens [kurzeAbwartenHoechstens] ab – so überschneidet sich
/// keine Diagnose mit einer Zahlung. Abbruch und Statusabfrage der laufenden
/// Zahlung bleiben frei – genau sie braucht die Kasse während einer Zahlung.
class TerminalBelegung {
  TerminalBelegung({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<TerminalBeleg> _belege = <TerminalBeleg>[];
  final List<KurzerAufruf> _kurze = <KurzerAufruf>[];

  /// Meldet einen kurzen Aufruf an; `null`, wenn ein langer das Terminal
  /// belegt (dann `terminal_busy`).
  KurzerAufruf? kurzBeginnen({
    required String? tid,
    required String host,
    required int port,
  }) {
    if (belegt(tid: tid, host: host, port: port)) return null;
    final kurz = KurzerAufruf._(tid, host, port);
    _kurze.add(kurz);
    return kurz;
  }

  /// Der kurze Aufruf ist fertig; ein zweites Beenden schadet nicht.
  void kurzBeenden(KurzerAufruf kurz) {
    _kurze.remove(kurz);
    if (!kurz._fertig.isCompleted) kurz._fertig.complete();
  }

  /// Wartet, bis kein kurzer Aufruf an das Terminal [tid] bzw. [host]:[port]
  /// mehr unterwegs ist – höchstens [hoechstens].
  Future<void> kurzeAbwarten({
    required String tid,
    required String host,
    required int port,
    Duration hoechstens = kurzeAbwartenHoechstens,
  }) async {
    final betroffen = _kurze
        .where(
          (k) =>
              (k.tid != null && k.tid!.isNotEmpty && gleicheTid(k.tid!, tid)) ||
              (k.host == host && k.port == port),
        )
        .map((k) => k._fertig.future)
        .toList();
    if (betroffen.isEmpty) return;
    try {
      await Future.wait(betroffen).timeout(hoechstens);
    } on TimeoutException {
      // Die Zahlung geht trotzdem: ein hängender kurzer Aufruf hält sie nie
      // länger auf.
    }
  }

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
