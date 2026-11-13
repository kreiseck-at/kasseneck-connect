import 'dart:async';
import 'dart:io';

/// In welcher Folge der Fake wartende Verbindungen bedient.
enum Bedienfolge {
  /// Die älteste zuerst.
  eingang,

  /// Die jüngste zuerst. Welche Verbindung ein Gerät als nächste bedient,
  /// sichert niemand zu: im Gerätetest 12.11.2026 (TM-T20III, zwei Connect an
  /// einem Drucker) lief A2 vor A1. Der Fake nimmt den ungünstigsten Fall.
  neuesteZuerst,
}

/// Eine Verbindung zum Fake, wie das Gerät sie erlebt.
class EinzelVerbindung {
  EinzelVerbindung(this._socket, this.angenommen);

  final Socket _socket;
  late final StreamSubscription<List<int>> _abo;

  /// Wann der Rechner verbunden hat (TCP angenommen, noch nicht bedient).
  final DateTime angenommen;

  /// Von wann bis wann das Gerät diese Verbindung bedient hat.
  DateTime? bedientAb;
  DateTime? bedientBis;

  /// Alle Bytes, die kamen.
  final List<int> bytes = <int>[];

  /// Die Bytes nach den Abfragen vorn (Druckdaten).
  final List<int> druckdaten = <int>[];

  final List<int> _offen = <int>[];
  bool _druckt = false;
  bool _fertig = false;

  /// Wie lange das Gerät sie bedient hat (`null`, solange es noch läuft).
  Duration? get gehalten {
    final ab = bedientAb;
    final bis = bedientBis;
    return ab == null || bis == null ? null : bis.difference(ab);
  }

  /// Ob nur Abfragen (`DLE EOT`, `GS I`) kamen.
  bool get nurAbfrage => bytes.isNotEmpty && druckdaten.isEmpty;

  Future<void> _schliessen() async {
    await _abo.cancel();
    _socket.destroy();
  }
}

/// Bondrucker auf TCP 9100, der nur EINE Verbindung zugleich bedient – wie
/// ein Epson TM-T20III (Gerätetest 12.11.2026).
///
/// Weitere Verbindungen nimmt er an (TCP), liest sie aber nicht und
/// beantwortet nichts, solange eine andere läuft. Endet die laufende (der
/// Rechner schließt), schließt er seine Seite ([schliesstSelbst]) und bedient
/// nach [freigabeVerzug] die nächste ([folge]).
///
/// Deckel offen ([deckelAuf]): Verbindungen werden weiter bedient, `DLE EOT`
/// und `GS I` bleiben unbeantwortet, und Bons bleiben im Puffer, bis der
/// Deckel zu ist ([deckelZu]) – dann druckt er sie in der Reihenfolge, in der
/// sie kamen.
class FakeEinzelDrucker {
  FakeEinzelDrucker._(this._server, this.folge);

  /// Startet den Fake auf einem freien Loopback-Port.
  static Future<FakeEinzelDrucker> start({
    Bedienfolge folge = Bedienfolge.eingang,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final drucker = FakeEinzelDrucker._(server, folge);
    drucker._annahme = server.listen(drucker._annehmen);
    return drucker;
  }

  final ServerSocket _server;
  StreamSubscription<Socket>? _annahme;

  /// Folge, in der wartende Verbindungen bedient werden.
  final Bedienfolge folge;

  /// Antworten auf `DLE EOT n` bei geschlossenem Deckel (Epson: feste Bits
  /// 0b0xx1xx10, nichts gemeldet).
  final Map<int, int> dleEot = <int, int>{1: 0x16, 2: 0x12, 3: 0x12, 4: 0x12};

  /// Antworten auf `GS I n` bei geschlossenem Deckel.
  final Map<int, String> gsI = <int, String>{};

  /// So lange nach dem Ende einer Verbindung bedient er die nächste noch
  /// nicht.
  Duration freigabeVerzug = Duration.zero;

  /// Ob er nach dem Ende einer Verbindung (Rechner hat geschlossen) seine
  /// Seite schließt. `false`: er bedient die nächste, lässt die alte aber
  /// offen stehen (Annahme, falls ein Gerät nie selbst schließt).
  bool schliesstSelbst = true;

  bool _deckelOffen = false;

  /// Ob der Deckel offen ist.
  bool get deckelOffen => _deckelOffen;

  /// Gedruckte Bons (Druckdaten je Verbindung) in Druckreihenfolge.
  final List<List<int>> bons = <List<int>>[];

  final List<List<int>> _puffer = <List<int>>[];

  /// Alle Verbindungen in der Reihenfolge ihrer Annahme.
  final List<EinzelVerbindung> verbindungen = <EinzelVerbindung>[];

  final List<EinzelVerbindung> _wartend = <EinzelVerbindung>[];
  EinzelVerbindung? _aktiv;
  DateTime _freiAb = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _freigabe;
  int _bedient = 0;
  int _hoechstBedient = 0;

  int get port => _server.port;

  /// Wie viele Verbindungen höchstens zugleich bedient wurden (immer 1).
  int get hoechstBedient => _hoechstBedient;

  /// Wie viele Verbindungen gerade warten.
  int get wartend => _wartend.length;

  /// Die Verbindungen, die nur Abfragen trugen.
  List<EinzelVerbindung> get abfragen =>
      verbindungen.where((v) => v.nurAbfrage).toList();

  /// Verbindungsaufbau für `EscPosAbfrage` und `PrinterRegistry` (jede
  /// Adresse führt hierher).
  Future<Socket> verbinden(String host, int port, {Duration? timeout}) =>
      Socket.connect(InternetAddress.loopbackIPv4, this.port, timeout: timeout);

  /// Deckel auf: keine Antworten mehr, Bons bleiben im Puffer.
  void deckelAuf() => _deckelOffen = true;

  /// Deckel zu: die gepufferten Bons laufen in ihrer Reihenfolge.
  void deckelZu() {
    _deckelOffen = false;
    bons.addAll(_puffer);
    _puffer.clear();
  }

  /// Hält das Gerät besetzt wie ein anderer Rechner: eine Verbindung, die
  /// erst nach [dauer] (ab dem Bedienen) schließt. Liefert, sobald sie
  /// bedient wird (dafür muss der Deckel zu sein: die Antwort auf `DLE EOT`
  /// zeigt es an).
  Future<void> fremdBelegen(Duration dauer) async {
    final socket = await verbinden('127.0.0.1', port);
    socket.done.ignore();
    final bedient = Completer<void>();
    socket.listen(
      (_) {
        if (!bedient.isCompleted) bedient.complete();
      },
      onError: (Object _) {},
      onDone: () {},
    );
    socket.add(<int>[0x10, 0x04, 0x01]);
    _fremde.add(socket);
    await bedient.future;
    _timer.add(Timer(dauer, socket.destroy));
  }

  final List<Timer> _timer = <Timer>[];
  final List<Socket> _fremde = <Socket>[];

  /// Wartet, bis [anzahl] Bons gedruckt sind.
  Future<void> warteAufBons(
    int anzahl, {
    Duration frist = const Duration(seconds: 10),
  }) async {
    final ende = DateTime.now().add(frist);
    while (bons.length < anzahl) {
      if (DateTime.now().isAfter(ende)) {
        throw StateError(
          'Fake-Einzeldrucker: ${bons.length} statt $anzahl Bons.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Wartet, bis keine Verbindung mehr läuft oder wartet.
  Future<void> warteBisRuhig({
    Duration frist = const Duration(seconds: 10),
  }) async {
    final ende = DateTime.now().add(frist);
    while (_aktiv != null || _wartend.isNotEmpty) {
      if (DateTime.now().isAfter(ende)) {
        throw StateError('Fake-Einzeldrucker: nicht ruhig.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void _annehmen(Socket socket) {
    // Antworten an eine schon geschlossene Gegenstelle scheitern über
    // `done`; das ist hier gewollt.
    socket.done.ignore();
    final v = EinzelVerbindung(socket, DateTime.now());
    verbindungen.add(v);
    v._abo = socket.listen(
      (daten) => _lesen(v, daten),
      onError: (Object _) => _ende(v),
      onDone: () => _ende(v),
    );
    // Angenommen, aber nicht gelesen, bis das Gerät sie bedient.
    v._abo.pause();
    _wartend.add(v);
    _bediene();
  }

  void _bediene() {
    if (_aktiv != null || _wartend.isEmpty) return;
    final rest = _freiAb.difference(DateTime.now());
    if (rest > Duration.zero) {
      _freigabe ??= Timer(rest, () {
        _freigabe = null;
        _bediene();
      });
      return;
    }
    final v = switch (folge) {
      Bedienfolge.eingang => _wartend.removeAt(0),
      Bedienfolge.neuesteZuerst => _wartend.removeLast(),
    };
    _aktiv = v;
    v.bedientAb = DateTime.now();
    _bedient++;
    if (_bedient > _hoechstBedient) _hoechstBedient = _bedient;
    v._abo.resume();
  }

  void _lesen(EinzelVerbindung v, List<int> daten) {
    v.bytes.addAll(daten);
    if (v._druckt) {
      v.druckdaten.addAll(daten);
      return;
    }
    v._offen.addAll(daten);
    while (v._offen.length >= 3) {
      final a = v._offen[0];
      final b = v._offen[1];
      final n = v._offen[2];
      final dle = a == 0x10 && b == 0x04;
      final gs = a == 0x1D && b == 0x49;
      if (!dle && !gs) {
        v._druckt = true;
        v.druckdaten.addAll(v._offen);
        v._offen.clear();
        return;
      }
      v._offen.removeRange(0, 3);
      if (_deckelOffen) continue;
      final antwort = dle
          ? (dleEot[n] == null ? null : <int>[dleEot[n]!])
          : (gsI[n] == null ? null : <int>[0x5F, ...gsI[n]!.codeUnits, 0]);
      if (antwort == null) continue;
      try {
        v._socket.add(antwort);
      } on Object {
        // Gegenstelle schon zu: die Antwort kommt eben nicht an.
      }
    }
  }

  void _ende(EinzelVerbindung v) {
    if (v._fertig) return;
    v._fertig = true;
    if (v._offen.isNotEmpty) {
      // Unvollständiger Rest: Druckdaten.
      v.druckdaten.addAll(v._offen);
      v._offen.clear();
    }
    if (v.druckdaten.isNotEmpty) {
      (_deckelOffen ? _puffer : bons).add(List<int>.of(v.druckdaten));
    }
    if (schliesstSelbst) v._socket.destroy();
    if (identical(_aktiv, v)) {
      _aktiv = null;
      _bedient--;
      v.bedientBis = DateTime.now();
      _freiAb = DateTime.now().add(freigabeVerzug);
    } else {
      // Eine wartende Verbindung, die vorher abriss.
      _wartend.remove(v);
    }
    _bediene();
  }

  Future<void> stop() async {
    _freigabe?.cancel();
    for (final timer in _timer) {
      timer.cancel();
    }
    for (final socket in _fremde) {
      socket.destroy();
    }
    await _annahme?.cancel();
    for (final v in verbindungen) {
      await v._schliessen();
    }
    await _server.close();
  }
}
