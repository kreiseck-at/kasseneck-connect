import 'dart:async';
import 'dart:io';

import 'escpos.dart';
import 'tcp9100.dart' show SocketConnector;

/// So lange wartet die Abfrage auf die erste Antwort (`DLE EOT 2`). Ein
/// ESC/POS-Drucker beantwortet Echtzeitbefehle sofort, im LAN in wenigen
/// Millisekunden, im WLAN selten über 100 ms. Was nach 250 ms nicht
/// antwortet, gilt als stumm – und kostet den Bon nicht das ganze Budget.
const Duration handshakeFrist = Duration(milliseconds: 250);

/// So lange bekommt ein Drucker, der schon gültig auf `DLE EOT` geantwortet
/// hat, für die Antwort. Gerätetest TM-T20III: Antwort in wenigen
/// Millisekunden; mit offenem Deckel oder ohne Papier nimmt er die Verbindung
/// an und schweigt. 500 ms trennen beides sicher.
const Duration bereitFrist = Duration(milliseconds: 500);

/// Versuche auf je neuer Verbindung, bevor ein statusfähiger Drucker als
/// nicht bereit gilt. Der zweite fängt einen Drucker ab, der gerade erst
/// wieder aufwacht.
const int bereitVersuche = 2;

/// Dauert der Verbindungsaufbau länger, ist das Netz langsam (verlorenes SYN,
/// WLAN wacht auf), und Schweigen danach sagt nichts über Deckel und Papier:
/// es gilt als unbekannt. Im LAN steht eine Verbindung in wenigen
/// Millisekunden, im WLAN selten nach mehr als 50 ms.
const Duration langsamerAufbau = Duration(milliseconds: 200);

/// So viel Zeit hält der erste Versuch von [EscPosAbfrage.frageBereit] für den
/// zweiten frei: ein Aufbau, der nicht langsam ist, und ein volles
/// Antwortfenster.
const Duration zweiterVersuchReserve = Duration(milliseconds: 700);

/// Ein `GS I` ohne gültige Antwort zählt für die Kennung nur, wenn es
/// mindestens so lange Zeit hatte (`EscPosAntworten.gsIOhneAntwortVoll`).
/// `GS I` ist kein Echtzeitbefehl; zu knapp gefragt, sagt Schweigen nichts.
const Duration gsIVolleFrist = Duration(seconds: 1);

/// Was eine Abfrage-Verbindung wissen will.
enum EscPosFrage {
  /// `DLE EOT 2`: Deckel, Stopp wegen Papierende.
  offlineGrund,

  /// `DLE EOT 4`: Rollensensor.
  rollensensor,

  /// `GS I 67`: Modellname.
  modell,

  /// `GS I 68`: Seriennummer.
  seriennummer,
}

/// Rohe Antworten einer Abfrage-Verbindung. Gedeutet wird anderswo
/// (`zustand.dart`, `kennung.dart`).
class EscPosAntworten {
  const EscPosAntworten({
    required this.verbunden,
    this.stumm = false,
    this.verbindungsFehler,
    this.offlineGrund,
    this.rollensensor,
    this.modell,
    this.seriennummer,
    this.gsIOhneAntwort = false,
    this.gsIOhneAntwortVoll = false,
  });

  /// Keine Verbindung zustande gekommen.
  const EscPosAntworten.ohneVerbindung(Object fehler)
    : verbunden = false,
      stumm = false,
      verbindungsFehler = fehler,
      offlineGrund = null,
      rollensensor = null,
      modell = null,
      seriennummer = null,
      gsIOhneAntwort = false,
      gsIOhneAntwortVoll = false;

  /// Ob die Verbindung stand.
  final bool verbunden;

  /// Warum sie nicht stand (`SocketException`, `TimeoutException`).
  final Object? verbindungsFehler;

  /// Antwortbyte auf `DLE EOT 2` mit gültigen festen Bits; sonst `null`.
  final int? offlineGrund;

  /// Antwortbyte auf `DLE EOT 4` mit gültigen festen Bits; sonst `null`.
  final int? rollensensor;

  /// Gültiger `GS I 67`-Rahmen; sonst `null`.
  final String? modell;

  /// Gültiger `GS I 68`-Rahmen; sonst `null`.
  final String? seriennummer;

  /// Ein `GS I` ging hinaus, aber es kam kein gültiger Rahmen zurück. Ein
  /// Gerät, das `DLE EOT` versteht, `GS I` aber nicht, könnte die Zeichen
  /// als Text puffern; danach geht auf dieser Verbindung kein weiteres
  /// `GS I` hinaus.
  final bool gsIOhneAntwort;

  /// Wie [gsIOhneAntwort], und das `GS I` hatte mindestens [gsIVolleFrist].
  final bool gsIOhneAntwortVoll;

  /// Das Gerät hat auf `DLE EOT 2` nachweislich geschwiegen: der Befehl ging
  /// hinaus, das volle Antwortfenster verstrich bei offener Verbindung, und
  /// der Aufbau war nicht langsam ([langsamerAufbau]). Nur dann sagt Schweigen
  /// etwas: ein Gerät, das kein ESC/POS spricht, bzw. ein statusfähiger
  /// Drucker, der nicht bereit ist.
  ///
  /// Alles andere ohne gültige Antwort – zu wenig Zeit, langsamer Aufbau,
  /// Gegenstelle schließt sofort – ist unbekannt (`stumm` `false`,
  /// [offlineGrund] `null`), und dann wird gedruckt wie bis 1.4.2.
  final bool stumm;
}

/// Fragt einen ESC/POS-Drucker über eine EIGENE, kurze Verbindung auf seinem
/// Rohport (9100) ab und schließt sie wieder.
///
/// Warum eine eigene Verbindung statt Fragen vor dem Beleg auf derselben: Auf
/// der Druckverbindung gehen so genau die Bytes der Kasse hinaus, Byte für Byte
/// wie bis 1.4.2 – auch an ein Gerät, das die Fragen nicht versteht.
///
/// Immer zuerst `DLE EOT 2`. `GS I` geht nur an ein Gerät, das darauf gültig
/// geantwortet hat: ein Bürodrucker auf 9100 (PCL, PostScript) druckte die
/// Zeichen `ID` sonst als Seite aus. `DLE EOT` selbst besteht nur aus
/// Steuerzeichen. Bleibt ein `GS I` ohne gültigen Rahmen, folgt keines mehr
/// (siehe [EscPosAntworten.gsIOhneAntwort]).
class EscPosAbfrage {
  EscPosAbfrage({
    SocketConnector? verbinden,
    this.aufbauGrenze = langsamerAufbau,
  }) : _verbinden = verbinden ?? Socket.connect;

  final SocketConnector _verbinden;

  /// Ab dieser Aufbauzeit ist Schweigen unbekannt ([langsamerAufbau]; Tests
  /// unter Last geben mehr vor).
  final Duration aufbauGrenze;

  /// Stellt [fragen] an [host]:[port]; alles zusammen höchstens [budget].
  ///
  /// [handshake] ist das Antwortfenster für `DLE EOT 2`. Es endet spätestens
  /// [reserve] vor dem Ende des Budgets (Platz für einen weiteren Versuch);
  /// wird es dadurch kürzer, kann Schweigen nicht mehr als `stumm` gelten.
  /// Was bis dahin nicht gültig beantwortet ist, bleibt `null` (unbekannt).
  /// Wirft nie.
  Future<EscPosAntworten> frage(
    String host,
    int port, {
    required Set<EscPosFrage> fragen,
    required Duration budget,
    Duration handshake = handshakeFrist,
    Duration reserve = Duration.zero,
  }) async {
    final uhr = Stopwatch()..start();
    Duration rest() {
      final r = budget - uhr.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    // Ohne Zeit wird nicht verbunden – und das ist keine Aussage über den
    // Drucker (kein Verbindungsfehler).
    if (budget <= Duration.zero) return const EscPosAntworten(verbunden: false);
    final Socket socket;
    try {
      socket = await _verbinden(host, port, timeout: rest());
    } on SocketException catch (e) {
      return EscPosAntworten.ohneVerbindung(e);
    } on TimeoutException catch (e) {
      return EscPosAntworten.ohneVerbindung(e);
    }
    final aufbau = uhr.elapsed;

    // Schreibfehler meldet ein Socket über `done`; sie zeigen sich hier schon
    // als ausbleibende Antwort (unbekannt) und dürfen nicht als unbehandelter
    // Fehler den Agenten erreichen.
    socket.done.ignore();
    final leser = _Leser(socket);
    try {
      final fenster = _kuerzer(handshake, rest() - reserve);
      final offline = await leser.statusByte(
        socket,
        dleEot(dleEotOfflineGrund),
        fenster,
      );
      final byte = offline.byte;
      if (byte == null) {
        return EscPosAntworten(
          verbunden: true,
          stumm:
              offline.geschwiegen &&
              fenster >= handshake &&
              aufbau <= aufbauGrenze,
        );
      }
      final rolle = fragen.contains(EscPosFrage.rollensensor)
          ? (await leser.statusByte(
              socket,
              dleEot(dleEotRollensensor),
              rest(),
            )).byte
          : null;
      // Je `GS I` nur, wenn das vorige einen gültigen Rahmen brachte.
      var gsIOhneAntwort = false;
      var gsIOhneAntwortVoll = false;
      Future<String?> gsIFrage(EscPosFrage frage, int n) async {
        final frist = rest();
        if (!fragen.contains(frage) ||
            gsIOhneAntwort ||
            frist <= Duration.zero) {
          return null;
        }
        final text = await leser.rahmen(socket, gsI(n), frist);
        if (text == null) {
          gsIOhneAntwort = true;
          gsIOhneAntwortVoll = frist >= gsIVolleFrist;
        }
        return text;
      }

      final modell = await gsIFrage(EscPosFrage.modell, gsIModell);
      final serie = await gsIFrage(EscPosFrage.seriennummer, gsISeriennummer);
      return EscPosAntworten(
        verbunden: true,
        offlineGrund: byte,
        rollensensor: rolle,
        modell: modell,
        seriennummer: serie,
        gsIOhneAntwort: gsIOhneAntwort,
        gsIOhneAntwortVoll: gsIOhneAntwortVoll,
      );
    } on SocketException {
      // Abgerissen mitten in den Fragen: was fehlt, ist unbekannt. Gedruckt
      // wurde auf dieser Verbindung ohnehin nichts.
      return const EscPosAntworten(verbunden: true);
    } finally {
      await leser.schliessen();
      socket.destroy();
    }
  }

  /// Fragt einen Drucker, der schon gültig geantwortet hat: je Versuch
  /// [bereitFrist] auf die erste Antwort, bei Schweigen ein zweiter Versuch
  /// auf neuer Verbindung (höchstens [bereitVersuche]).
  ///
  /// `stumm` (also „nicht bereit“) steht nur, wenn JEDER Versuch nachweislich
  /// geschwiegen hat. Der erste hält dafür [zweiterVersuchReserve] frei; reicht
  /// die Zeit trotzdem nicht, ist das Ergebnis unbekannt.
  Future<EscPosAntworten> frageBereit(
    String host,
    int port, {
    required Set<EscPosFrage> fragen,
    required Duration budget,
  }) async {
    final uhr = Stopwatch()..start();
    for (var versuch = 1; ; versuch++) {
      final letzter = versuch >= bereitVersuche;
      final antworten = await frage(
        host,
        port,
        fragen: fragen,
        budget: budget - uhr.elapsed,
        handshake: bereitFrist,
        reserve: letzter ? Duration.zero : bereitFrist + aufbauGrenze,
      );
      if (!antworten.stumm || letzter) return antworten;
    }
  }

  static Duration _kuerzer(Duration a, Duration b) {
    final kurz = a < b ? a : b;
    return kurz.isNegative ? Duration.zero : kurz;
  }
}

/// Sammelt die Antwortbytes einer Abfrage-Verbindung.
class _Leser {
  _Leser(Socket socket) {
    _abo = socket.listen(
      (daten) {
        _puffer.addAll(daten);
        _wecken();
      },
      onError: (Object _) {
        _beendet = true;
        _wecken();
      },
      onDone: () {
        _beendet = true;
        _wecken();
      },
      cancelOnError: true,
    );
  }

  late final StreamSubscription<List<int>> _abo;
  final List<int> _puffer = <int>[];
  Completer<void>? _wartet;
  bool _beendet = false;

  void _wecken() {
    final wartet = _wartet;
    _wartet = null;
    if (wartet != null && !wartet.isCompleted) wartet.complete();
  }

  /// Wartet auf neue Bytes, bis [uhr] [frist] erreicht; `false`, wenn keine
  /// mehr kommen können oder die Frist um ist.
  Future<bool> _mehr(Stopwatch uhr, Duration frist) async {
    if (_beendet) return false;
    final rest = frist - uhr.elapsed;
    if (rest <= Duration.zero) return false;
    final wartet = _wartet = Completer<void>();
    try {
      await wartet.future.timeout(rest);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Schickt [befehl] und liefert das erste Byte mit gültigen festen Bits
  /// (andere Bytes, etwa ASB-Blöcke, werden übergangen).
  ///
  /// `geschwiegen` heißt: gefragt, die ganze [frist] gewartet, und die
  /// Verbindung stand bis zuletzt. Ohne Zeit wird gar nicht erst gefragt.
  Future<({int? byte, bool geschwiegen})> statusByte(
    Socket socket,
    List<int> befehl,
    Duration frist,
  ) async {
    if (frist <= Duration.zero) return (byte: null, geschwiegen: false);
    _puffer.clear();
    socket.add(befehl);
    final uhr = Stopwatch()..start();
    while (true) {
      while (_puffer.isNotEmpty) {
        final byte = _puffer.removeAt(0);
        if (istEchtzeitStatus(byte)) return (byte: byte, geschwiegen: false);
      }
      if (!await _mehr(uhr, frist)) {
        return (byte: null, geschwiegen: !_beendet);
      }
    }
  }

  /// Schickt [befehl] und liefert den Inhalt eines gültigen `GS I`-Rahmens.
  Future<String?> rahmen(
    Socket socket,
    List<int> befehl,
    Duration frist,
  ) async {
    // Ohne Zeit für die Antwort wird gar nicht erst gefragt.
    if (frist <= Duration.zero) return null;
    _puffer.clear();
    socket.add(befehl);
    final uhr = Stopwatch()..start();
    while (true) {
      switch (leseGsIRahmen(_puffer)) {
        case GsIGueltig(:final text):
          return text;
        case GsIUngueltig():
          return null;
        case GsIUnvollstaendig():
          if (!await _mehr(uhr, frist)) return null;
      }
    }
  }

  Future<void> schliessen() => _abo.cancel();
}
