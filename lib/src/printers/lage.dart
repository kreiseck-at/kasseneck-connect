import 'kennung.dart';
import 'zustand.dart';

/// So lange gilt ein Gerät nach einer Abfrage ohne gültige Antwort als stumm:
/// vor seinen Bons geht keine Abfrage-Verbindung hinaus, gedruckt wird ohne
/// Zuschlag wie bis 1.4.2, und der Takt prüft nur die Erreichbarkeit. Zehn
/// Minuten, damit ein Drucker, der nur kurz beschäftigt war, bald wieder
/// geprüft wird.
const Duration stummDauer = Duration(minutes: 10);

/// Mindestens so lange nach dem letzten Bon gilt Schweigen des Druckers als
/// unbekannt: ein Drucker, der noch druckt (Empfangspuffer voll), beantwortet
/// `DLE EOT` womöglich erst danach.
const Duration druckNachlaufMindestens = Duration(seconds: 3);

/// Geschätzte Druckrate für den Nachlauf, bewusst niedrig: Text druckt ein
/// Bondrucker mit gut 2 KB je Sekunde, Rastergrafik viel schneller. Wer zu
/// lange von „druckt noch“ ausgeht, druckt wie bis 1.4.2; wer zu kurz, meldet
/// einen bereiten Drucker als nicht bereit.
const int druckRateBytesJeSekunde = 1000;

/// So lange druckt ein Bon mit [bytes] Bytes nach dem letzten gesendeten Byte
/// höchstens noch nach (großzügig geschätzt).
Duration druckNachlauf(int bytes) =>
    druckNachlaufMindestens +
    Duration(milliseconds: bytes * 1000 ~/ druckRateBytesJeSekunde);

/// So lange muss ein statusfähiger Drucker ohne Unterbrechung geschwiegen
/// haben, bevor Schweigen „nicht bereit“ heißt: die erste Beobachtung
/// (Statustakt oder ein früherer Bon) liegt mindestens so lange zurück, und
/// seitdem kam keine gültige Antwort.
///
/// Warum nicht zwei Versuche im selben Bon: ein Drucker, der gerade den Bon
/// eines anderen Rechners druckt, schweigt ebenso – und ein Tagesabschluss
/// von 25 KB druckt gut 12 s. Zwei Versuche mit 2 s Abstand passten nicht in
/// das Budget von 1,5 s (Vorgabe des Inhabers) und hielten so einen Fremdbon
/// auch nicht aus. 30 s Schweigen am Stück hat ein druckender Drucker nicht,
/// ein offener Deckel oder eine fehlende Rolle schon. Bis dahin wird gedruckt
/// wie bis 1.4.2 (ein Epson-Drucker hält die Daten, bis er wieder bereit ist).
const Duration schweigenMindestdauer = Duration(seconds: 30);

/// So lange nach einer eigenen Verbindung gilt eine abgelehnte neue als
/// „gibt noch nicht frei“ statt „aus“; ebenso lange wiederholt die
/// Warteschlange die Druckverbindung dann in kurzen Schritten (es ging
/// nachweislich nichts hinaus).
const Duration freigabeFenster = Duration(seconds: 3);

/// Abstand der Wiederholungen innerhalb von [freigabeFenster].
const Duration freigabeSchritt = Duration(milliseconds: 250);

/// Ob das Schweigen eines statusfähigen Druckers „nicht bereit“ heißen darf.
///
/// Nur, wenn feststeht, dass unter der Adresse derselbe Drucker hängt – gleiche
/// MAC oder frisch bestätigte Kennung, und keine andere MAC –, kein Bon aus
/// diesem Prozess mehr druckt und er schon [schweigenMindestdauer] am Stück
/// schweigt. Sonst kann ein getauschtes Gerät schweigen, das nie ein
/// Statusdrucker war, oder ein Drucker, der gerade (auch fremd) druckt; dann
/// ist der Zustand unbekannt, und gedruckt wird wie bis 1.4.2.
bool schweigenHeisstNichtBereit({
  required MacVergleich mac,
  required DruckerLage lage,
  required DateTime jetzt,
}) =>
    mac != MacVergleich.anders &&
    (mac == MacVergleich.gleich || lage.frisch(jetzt)) &&
    !lage.druckt(jetzt) &&
    lage.schweigtLangeGenug(jetzt);

/// Was Connect im Lauf über einen Drucker weiß – nur im Speicher.
///
/// Der Stand altert sofort und hat in der `config.json` nichts verloren; nach
/// einem Neustart beginnt jeder Drucker als „unbekannt“, wie bis 1.4.2.
class DruckerLage {
  /// Zuletzt gemeldetes Papier und Deckel.
  DruckerZustand zustand = DruckerZustand.unbekannt;

  /// Wann [zustand] gemeldet wurde; `null`: nie.
  DateTime? zustandAm;

  /// Wie oft der Statustakt den Drucker zuletzt hintereinander nicht sah.
  int verfehltInFolge = 0;

  /// Letzte Beurteilung der Kennung unter der eingerichteten Adresse.
  KennungsLage kennung = KennungsLage.unbekannt;

  /// Wann die Kennung zuletzt bestätigt wurde (Seriennummer oder MAC).
  DateTime? kennungBestaetigtAm;

  /// Seriennummer, die ein anderes Gerät unter der Adresse nannte.
  String? konfliktSerie;

  /// Bis wann nach einem Konflikt ohne Fund nicht erneut vor jedem Bon
  /// gesucht wird.
  DateTime? konfliktSucheBis;

  /// Bis wann das Gerät als stumm gilt (keine gültige `DLE EOT`-Antwort):
  /// bis dahin keine Abfrage-Verbindung vor dem Druck.
  DateTime? stummBis;

  /// Wann zuletzt eine Erkennung lief (auch eine ohne Ergebnis).
  DateTime? letzteErkennung;

  /// Bis wann der zuletzt aus diesem Prozess gesendete Bon vermutlich noch
  /// druckt ([druckNachlauf]); bis dahin ist Schweigen unbekannt.
  DateTime? drucktBis;

  /// Seit wann der (statusfähige) Drucker ohne Unterbrechung schweigt;
  /// `null`, solange er antwortet.
  DateTime? schweigtSeit;

  /// Der Drucker gab eine Verbindung nach dem Schließen erst verzögert frei
  /// (die Druckverbindung direkt nach der Abfrage wurde abgelehnt). Dann
  /// spricht Connect vor seinen Bons und im Takt nicht mehr mit ihm – Druck
  /// wie bis 1.4.2. Nur im Speicher: nach einem Neustart prüft Connect neu.
  bool gibtLangsamFrei = false;

  /// Seit wann unter der Adresse dieselbe fremde Seriennummer
  /// ([konfliktSerie]) antwortet, und wie oft vor einem Bon.
  DateTime? konfliktSeit;
  int konfliktBons = 0;

  /// Ob die Übernahme der fremden Kennung schon angestoßen ist.
  bool ersetzenAngestossen = false;

  /// Seit wann die letzte eigene Verbindung zum Drucker zu ist (Abfrage,
  /// Takt, Bon) – in Echtzeit, denn die Freigabe ist ein Verhalten des
  /// Geräts.
  Stopwatch? _seitVerbindung;

  /// Eine eigene Verbindung zum Drucker stand eben.
  void verbunden() => _seitVerbindung = Stopwatch()..start();

  /// Ob die letzte eigene Verbindung höchstens [freigabeFenster] her ist.
  bool ebenVerbunden() {
    final uhr = _seitVerbindung;
    return uhr != null && uhr.elapsed < freigabeFenster;
  }

  /// Tag (`JJJJ-MM-TT`) der letzten Logzeile „Kennung nicht prüfbar“: eine
  /// je Tag reicht.
  String? letzterHinweisTag;

  /// Ob die Kennung bis [jetzt] als frisch bestätigt gilt.
  bool frisch(DateTime jetzt) {
    final am = kennungBestaetigtAm;
    if (am == null) return false;
    final alter = jetzt.difference(am);
    return !alter.isNegative && alter < kennungFrisch;
  }

  /// Merkt sich: an [am] gingen [bytes] Bytes eines Bons hinaus.
  void druckGesendet(int bytes, DateTime am) {
    final bis = am.add(druckNachlauf(bytes));
    final bisher = drucktBis;
    if (bisher == null || bis.isAfter(bisher)) drucktBis = bis;
  }

  /// Ob der letzte Bon bis [jetzt] vermutlich noch druckt.
  bool druckt(DateTime jetzt) {
    final bis = drucktBis;
    return bis != null && jetzt.isBefore(bis);
  }

  /// Eine Abfrage blieb ohne gültige Antwort (nachgewiesenes Schweigen).
  void schweigt(DateTime jetzt) => schweigtSeit ??= jetzt;

  /// Eine gültige Antwort beendet das Schweigen.
  void antwortet() => schweigtSeit = null;

  /// Ob der Drucker bis [jetzt] schon [schweigenMindestdauer] am Stück
  /// schweigt.
  bool schweigtLangeGenug(DateTime jetzt) {
    final seit = schweigtSeit;
    return seit != null && jetzt.difference(seit) >= schweigenMindestdauer;
  }

  /// Merkt sich ab [jetzt] für [stummDauer]: das Gerät schweigt.
  void alsStummMerken(DateTime jetzt) => stummBis = jetzt.add(stummDauer);

  /// Ob das Gerät bis [jetzt] als stumm gilt.
  bool stumm(DateTime jetzt) {
    final bis = stummBis;
    return bis != null && jetzt.isBefore(bis);
  }
}

/// Die Lagen aller Drucker, je Drucker-ID.
class DruckerLagen {
  final Map<String, DruckerLage> _lagen = <String, DruckerLage>{};

  /// Die Lage von [id]; legt sie beim ersten Zugriff an.
  DruckerLage von(String id) => _lagen.putIfAbsent(id, DruckerLage.new);

  /// Die Lage von [id], ohne eine anzulegen.
  DruckerLage? vorhanden(String id) => _lagen[id];

  /// Vergisst [id] (Drucker entfernt oder neu adressiert).
  void vergiss(String id) => _lagen.remove(id);
}
