import 'dart:async';
import 'dart:io';

/// Verhalten des Fake-Druckers.
enum FakePrinterMode {
  /// Nimmt die Bytes entgegen und merkt sie sich.
  accept,

  /// Nimmt die Verbindung an, liest aber **nie** — der Sendepuffer läuft voll
  /// und der Schreibvorgang bleibt stehen (Zeitlimit prüfen).
  hang,

  /// Wirft die Verbindung sofort weg (Transportfehler prüfen).
  reset,
}

/// Eine Verbindung zum Fake: wann sie stand und welche Bytes kamen.
class FakeVerbindung {
  FakeVerbindung(this.beginn);

  final DateTime beginn;
  DateTime? ende;
  final List<int> bytes = <int>[];

  /// Wann das erste und das letzte Byte ankam (`null` ohne Bytes).
  DateTime? ersterByte;
  DateTime? letzterByte;
}

/// Fake-Bondrucker auf TCP 9100: nimmt rohe Bytes an und protokolliert sie.
///
/// Auf Wunsch beantwortet er wie ein Epson-TM `DLE EOT n` (ein Byte aus
/// [dleEot]) und `GS I n` (Rahmen `_…\0` aus [gsI]); ohne Eintrag schweigt er
/// – wie ein Gerät, das die Befehle nicht kennt.
class FakeTcpPrinter {
  FakeTcpPrinter._(this._server, this.mode);

  /// Startet den Fake auf einem freien Loopback-Port.
  static Future<FakeTcpPrinter> start({
    FakePrinterMode mode = FakePrinterMode.accept,
    Map<int, int>? dleEot,
    Map<int, String>? gsI,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final printer = FakeTcpPrinter._(server, mode);
    if (dleEot != null) printer.dleEot.addAll(dleEot);
    if (gsI != null) printer.gsI.addAll(gsI);
    printer._subscription = server.listen(printer._handle);
    return printer;
  }

  /// Antworten auf `DLE EOT n` (n → Byte). Ohne Eintrag: keine Antwort.
  final Map<int, int> dleEot = <int, int>{};

  /// Antworten auf `GS I n` (n → Text im Rahmen). Ohne Eintrag: keine.
  final Map<int, String> gsI = <int, String>{};

  /// Rohe Antwort auf `GS I n` statt eines sauberen Rahmens (Rauschen).
  final Map<int, List<int>> gsIRoh = <int, List<int>>{};

  /// Verzögerung jeder Antwort.
  Duration antwortVerzug = Duration.zero;

  final ServerSocket _server;

  /// Verhalten dieses Fakes.
  final FakePrinterMode mode;

  final List<int> _received = <int>[];
  final List<Socket> _open = <Socket>[];
  final List<StreamSubscription<List<int>>> _reads =
      <StreamSubscription<List<int>>>[];
  final List<Timer> _timer = <Timer>[];
  StreamSubscription<Socket>? _subscription;
  int _connections = 0;
  int _gleichzeitig = 0;
  int _hoechstGleichzeitig = 0;

  /// Alle Verbindungen in ihrer Reihenfolge.
  final List<FakeVerbindung> verbindungen = <FakeVerbindung>[];

  int get port => _server.port;

  /// Alle bisher empfangenen Bytes (über alle Verbindungen).
  List<int> get received => List<int>.unmodifiable(_received);

  /// Wie oft sich jemand verbunden hat.
  int get connections => _connections;

  /// Wie viele Verbindungen höchstens zugleich Bytes schickten: die
  /// Zeiträume vom ersten bis zum letzten Byte je Verbindung. Gemessen an
  /// Annahme und Schließen sähe es anders aus – das Schließen meldet sich
  /// hier oft erst nach der nächsten Annahme, obwohl der Absender längst
  /// fertig war.
  int get hoechstGleichzeitig {
    final punkte =
        <(DateTime, int)>[
          for (final v in verbindungen)
            if (v.ersterByte != null) ...<(DateTime, int)>[
              (v.ersterByte!, 1),
              (v.letzterByte!, -1),
            ],
        ]..sort((a, b) {
          final zeit = a.$1.compareTo(b.$1);
          // Bei gleicher Zeit zuerst das Ende: Ende und Beginn im selben
          // Augenblick ist keine Überschneidung.
          return zeit != 0 ? zeit : a.$2.compareTo(b.$2);
        });
    var aktiv = 0;
    var hoechst = 0;
    for (final (_, schritt) in punkte) {
      aktiv += schritt;
      if (aktiv > hoechst) hoechst = aktiv;
    }
    return hoechst;
  }

  /// Wie viele Verbindungen höchstens zugleich angenommen waren (Annahme bis
  /// Schließen, wie der Fake es sieht).
  int get hoechstAngenommen => _hoechstGleichzeitig;

  /// Die Bytes der Druckverbindungen (alles, was nicht nur aus Abfragen
  /// `DLE EOT`/`GS I` bestand).
  List<List<int>> get druckVerbindungen => verbindungen
      .map((v) => v.bytes)
      .where((b) => b.isNotEmpty && !nurAbfragen(b))
      .toList();

  /// Die Bytes der Verbindungen, die nur Abfragen trugen.
  List<List<int>> get abfrageVerbindungen => verbindungen
      .map((v) => v.bytes)
      .where((b) => b.isNotEmpty && nurAbfragen(b))
      .toList();

  /// Ob [bytes] nur aus dreibytigen `DLE EOT n`/`GS I n` bestehen.
  static bool nurAbfragen(List<int> bytes) {
    if (bytes.length % 3 != 0) return false;
    for (var i = 0; i < bytes.length; i += 3) {
      final dle = bytes[i] == 0x10 && bytes[i + 1] == 0x04;
      final gs = bytes[i] == 0x1D && bytes[i + 1] == 0x49;
      if (!dle && !gs) return false;
    }
    return true;
  }

  void _handle(Socket socket) {
    // Antworten an eine schon geschlossene Gegenstelle scheitern über `done`;
    // das ist hier gewollt und kein Testfehler.
    socket.done.ignore();
    _connections++;
    final verbindung = FakeVerbindung(DateTime.now());
    verbindungen.add(verbindung);
    _gleichzeitig++;
    if (_gleichzeitig > _hoechstGleichzeitig) {
      _hoechstGleichzeitig = _gleichzeitig;
    }
    var geschlossen = false;
    void zu() {
      if (geschlossen) return;
      geschlossen = true;
      _gleichzeitig--;
      verbindung.ende = DateTime.now();
    }

    switch (mode) {
      case FakePrinterMode.accept:
        final offen = <int>[];
        var druckdaten = false;
        _reads.add(
          socket.listen(
            (daten) {
              final jetzt = DateTime.now();
              verbindung
                ..ersterByte ??= jetzt
                ..letzterByte = jetzt;
              _received.addAll(daten);
              verbindung.bytes.addAll(daten);
              if (druckdaten) return;
              offen.addAll(daten);
              druckdaten = _antworte(socket, offen);
            },
            onError: (Object _) => zu(),
            onDone: () {
              zu();
              socket.destroy();
            },
          ),
        );
      case FakePrinterMode.hang:
        // Bewusst nicht lesen: die Verbindung steht, der Absender läuft voll.
        _open.add(socket);
      case FakePrinterMode.reset:
        zu();
        socket.destroy();
    }
  }

  /// Beantwortet vollständige Befehle vorn in [offen]; `true`, sobald etwas
  /// anderes kommt (Druckdaten – ab da wird nichts mehr beantwortet).
  bool _antworte(Socket socket, List<int> offen) {
    while (offen.length >= 3) {
      final a = offen[0];
      final b = offen[1];
      final n = offen[2];
      List<int>? antwort;
      if (a == 0x10 && b == 0x04) {
        final byte = dleEot[n];
        if (byte != null) antwort = <int>[byte];
      } else if (a == 0x1D && b == 0x49) {
        final roh = gsIRoh[n];
        final text = gsI[n];
        if (roh != null) {
          antwort = roh;
        } else if (text != null) {
          antwort = <int>[0x5F, ...text.codeUnits, 0x00];
        }
      } else {
        offen.clear();
        return true;
      }
      offen.removeRange(0, 3);
      if (antwort != null) {
        final senden = antwort;
        if (antwortVerzug == Duration.zero) {
          _schreibe(socket, senden);
        } else {
          _timer.add(Timer(antwortVerzug, () => _schreibe(socket, senden)));
        }
      }
    }
    return false;
  }

  static void _schreibe(Socket socket, List<int> bytes) {
    try {
      socket.add(bytes);
    } on StateError {
      // Verbindung schon zu: die Antwort kommt eben nicht an.
    }
  }

  /// Wartet, bis mehr als [vorher] Druckverbindungen da und alle
  /// Verbindungen wieder zu sind.
  ///
  /// Der Absender ist fertig, wenn sein Auftrag zurückkommt; Annehmen und
  /// Lesen hier können dann noch nachlaufen. Wer nur auf „alles zu“ wartete,
  /// sähe eine Verbindung, die noch gar nicht angenommen ist, nicht.
  Future<void> warteAufDruck(
    int vorher, {
    Duration frist = const Duration(seconds: 5),
  }) async {
    final ende = DateTime.now().add(frist);
    while (druckVerbindungen.length <= vorher || _gleichzeitig > 0) {
      if (DateTime.now().isAfter(ende)) {
        throw StateError(
          'Fake-Drucker: nach $vorher kam kein weiterer Druck an.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Wartet, bis die zuletzt angenommene Verbindung geschlossen ist.
  Future<void> ruhigNachVerbindung({
    Duration frist = const Duration(seconds: 5),
  }) async {
    final ende = DateTime.now().add(frist);
    while (verbindungen.isEmpty || verbindungen.last.ende == null) {
      if (DateTime.now().isAfter(ende)) {
        throw StateError('Fake-Drucker: keine geschlossene Verbindung.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> stop() async {
    for (final timer in _timer) {
      timer.cancel();
    }
    for (final read in _reads) {
      await read.cancel();
    }
    _reads.clear();
    for (final socket in _open) {
      socket.destroy();
    }
    _open.clear();
    await _subscription?.cancel();
    _subscription = null;
    await _server.close();
  }
}
