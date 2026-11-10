import 'dart:async';
import 'dart:io';

import 'escpos.dart';
import 'tcp9100.dart' show SocketConnector;

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
    this.verbindungsFehler,
    this.offlineGrund,
    this.rollensensor,
    this.modell,
    this.seriennummer,
  });

  /// Keine Verbindung zustande gekommen.
  const EscPosAntworten.ohneVerbindung(Object fehler)
    : verbunden = false,
      verbindungsFehler = fehler,
      offlineGrund = null,
      rollensensor = null,
      modell = null,
      seriennummer = null;

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

  /// Verbunden, aber keine gültige Antwort auf `DLE EOT` – ein Gerät, das kein
  /// ESC/POS spricht oder Echtzeitbefehle abgeschaltet hat.
  bool get stumm => verbunden && offlineGrund == null;
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
/// Steuerzeichen.
class EscPosAbfrage {
  EscPosAbfrage({SocketConnector? verbinden})
    : _verbinden = verbinden ?? Socket.connect;

  final SocketConnector _verbinden;

  /// Stellt [fragen] an [host]:[port]; alles zusammen höchstens [budget].
  ///
  /// Was bis dahin nicht gültig beantwortet ist, bleibt `null` (unbekannt).
  /// Wirft nie.
  Future<EscPosAntworten> frage(
    String host,
    int port, {
    required Set<EscPosFrage> fragen,
    required Duration budget,
  }) async {
    final uhr = Stopwatch()..start();
    Duration rest() {
      final r = budget - uhr.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    final Socket socket;
    try {
      socket = await _verbinden(host, port, timeout: rest());
    } on SocketException catch (e) {
      return EscPosAntworten.ohneVerbindung(e);
    } on TimeoutException catch (e) {
      return EscPosAntworten.ohneVerbindung(e);
    }

    // Schreibfehler meldet ein Socket über `done`; sie zeigen sich hier schon
    // als ausbleibende Antwort (unbekannt) und dürfen nicht als unbehandelter
    // Fehler den Agenten erreichen.
    socket.done.ignore();
    final leser = _Leser(socket);
    try {
      final offline = await leser.statusByte(
        socket,
        dleEot(dleEotOfflineGrund),
        rest(),
      );
      if (offline == null) {
        return const EscPosAntworten(verbunden: true);
      }
      final rolle = fragen.contains(EscPosFrage.rollensensor)
          ? await leser.statusByte(socket, dleEot(dleEotRollensensor), rest())
          : null;
      final modell = fragen.contains(EscPosFrage.modell)
          ? await leser.rahmen(socket, gsI(gsIModell), rest())
          : null;
      final serie = fragen.contains(EscPosFrage.seriennummer)
          ? await leser.rahmen(socket, gsI(gsISeriennummer), rest())
          : null;
      return EscPosAntworten(
        verbunden: true,
        offlineGrund: offline,
        rollensensor: rolle,
        modell: modell,
        seriennummer: serie,
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
  Future<int?> statusByte(
    Socket socket,
    List<int> befehl,
    Duration frist,
  ) async {
    _puffer.clear();
    socket.add(befehl);
    final uhr = Stopwatch()..start();
    while (true) {
      while (_puffer.isNotEmpty) {
        final byte = _puffer.removeAt(0);
        if (istEchtzeitStatus(byte)) return byte;
      }
      if (!await _mehr(uhr, frist)) return null;
    }
  }

  /// Schickt [befehl] und liefert den Inhalt eines gültigen `GS I`-Rahmens.
  Future<String?> rahmen(
    Socket socket,
    List<int> befehl,
    Duration frist,
  ) async {
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
