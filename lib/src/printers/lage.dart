import 'kennung.dart';
import 'zustand.dart';

/// So lange gilt ein Gerät nach einer Abfrage ohne gültige Antwort als stumm:
/// vor seinen Bons geht keine Abfrage-Verbindung hinaus, gedruckt wird ohne
/// Zuschlag wie bis 1.4.2, und der Takt prüft nur die Erreichbarkeit. Zehn
/// Minuten, damit ein Drucker, der nur kurz beschäftigt war, bald wieder
/// geprüft wird.
const Duration stummDauer = Duration(minutes: 10);

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
