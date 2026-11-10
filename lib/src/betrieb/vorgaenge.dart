import 'dart:async';

/// Längster Vorgang, der Update und Ruhezustand aufhält (Spec 1.5: die
/// Zahlung mit 4 min, dazu Verbindungsaufbau und Puffer). Ein Vorgang, der
/// nach 6 min nicht beendet ist, gilt als verwaist und zählt nicht mehr – eine
/// Sperre darf nie bleiben, auch wenn ein Fehler das Ende verschluckt.
const Duration vorgangHoechstdauer = Duration(minutes: 6);

/// Kürzester Abstand, in dem der Ablauf-Timer erneut nachsieht.
const Duration _mindestAbstand = Duration(seconds: 1);

/// Was gerade läuft.
enum VorgangsArt {
  /// Ein Druckauftrag in der Warteschlange.
  druck,

  /// Ein langer Terminal-Aufruf (Zahlung, Gutschrift, Aufhebung).
  terminal,
}

/// Ein laufender Vorgang; beendet über [LaufendeVorgaenge.beende].
class Vorgang {
  Vorgang._(this.art, this.seit);

  final VorgangsArt art;
  final DateTime seit;
}

/// Wird bei Übergängen zwischen „nichts läuft“ und „etwas läuft“ gerufen
/// (`betrieb.lock`, Schlafsperre). Darf nicht werfen und nicht warten.
abstract interface class BetriebsBeobachter {
  /// Der erste Vorgang beginnt.
  void belegt();

  /// Der letzte Vorgang ist beendet oder abgelaufen.
  void frei();
}

/// Zählt die laufenden Vorgänge des Agenten – prozessweit, für alle Kassen,
/// Tabs und Tokens zusammen.
///
/// Daran hängen Update- und Neustart-Sperre (`update_device_busy`,
/// `restart_busy`), die Datei `betrieb.lock` und die Schlafsperre.
class LaufendeVorgaenge {
  LaufendeVorgaenge({
    DateTime Function()? clock,
    List<BetriebsBeobachter> beobachter = const <BetriebsBeobachter>[],
    this.hoechstdauer = vorgangHoechstdauer,
  }) : _clock = clock ?? DateTime.now,
       _beobachter = List<BetriebsBeobachter>.of(beobachter);

  final DateTime Function() _clock;
  final List<BetriebsBeobachter> _beobachter;

  /// Ab wann ein Vorgang als verwaist gilt.
  final Duration hoechstdauer;

  final List<Vorgang> _laufend = <Vorgang>[];
  final List<Completer<void>> _wartende = <Completer<void>>[];
  Timer? _ablauf;

  /// Meldet einen weiteren Beobachter an.
  void beobachte(BetriebsBeobachter beobachter) => _beobachter.add(beobachter);

  /// Ob gerade etwas läuft (verwaiste Vorgänge zählen nicht).
  bool get laufen {
    _aufraeumen();
    return _laufend.isNotEmpty;
  }

  /// Wie viele Vorgänge laufen.
  int get anzahl {
    _aufraeumen();
    return _laufend.length;
  }

  /// Beginnt einen Vorgang.
  Vorgang beginne(VorgangsArt art) {
    _aufraeumen();
    final vorgang = Vorgang._(art, _clock());
    final warLeer = _laufend.isEmpty;
    _laufend.add(vorgang);
    if (warLeer) {
      for (final b in _beobachter) {
        b.belegt();
      }
    }
    _ablaufPlanen();
    return vorgang;
  }

  /// Beendet [vorgang]; ein zweites Beenden schadet nicht.
  void beende(Vorgang vorgang) {
    if (!_laufend.remove(vorgang)) return;
    _vielleichtFrei();
  }

  /// Wartet, bis nichts mehr läuft; `false`, wenn nach [hoechstens] noch etwas
  /// läuft.
  Future<bool> leer({required Duration hoechstens}) async {
    if (!laufen) return true;
    final warte = Completer<void>();
    _wartende.add(warte);
    try {
      await warte.future.timeout(hoechstens);
      return true;
    } on TimeoutException {
      return !laufen;
    } finally {
      _wartende.remove(warte);
    }
  }

  void _aufraeumen() {
    final jetzt = _clock();
    final vorher = _laufend.length;
    _laufend.removeWhere((v) => jetzt.difference(v.seit) >= hoechstdauer);
    if (vorher > 0 && _laufend.length < vorher) _vielleichtFrei();
  }

  void _vielleichtFrei() {
    if (_laufend.isNotEmpty) return;
    _ablauf?.cancel();
    _ablauf = null;
    for (final b in _beobachter) {
      b.frei();
    }
    for (final w in _wartende.toList()) {
      if (!w.isCompleted) w.complete();
    }
  }

  /// Ein Timer zum Ablauf des ältesten Vorgangs: auch ohne weitere Anfrage
  /// werden verwaiste Vorgänge frei.
  void _ablaufPlanen() {
    if (_laufend.isEmpty) return;
    _ablauf?.cancel();
    final aeltester = _laufend
        .map((v) => v.seit)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final bis = hoechstdauer - _clock().difference(aeltester);
    // Nie kürzer als [_mindestAbstand]: verstellt sich die Uhr, soll der
    // Timer nicht im Kreis laufen.
    _ablauf = Timer(bis < _mindestAbstand ? _mindestAbstand : bis, () {
      _ablauf = null;
      _aufraeumen();
      _ablaufPlanen();
    });
  }

  /// Hält den Ablauf-Timer an (Agent stoppt).
  void stop() {
    _ablauf?.cancel();
    _ablauf = null;
  }
}
