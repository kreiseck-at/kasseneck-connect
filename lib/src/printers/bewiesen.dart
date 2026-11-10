/// Druckermodelle, deren Verhalten im Gerätetest belegt ist.
///
/// Grundsatz des Inhabers: „es darf nicht kaputt gehen“ geht vor Abdeckung.
/// Alles, was vor einem Bon mit dem Drucker spricht – Papier und Deckel,
/// `printer_not_ready`, die Kennungsprüfung – und der Statustakt laufen nur
/// für Drucker, deren über `GS I 67` gelesenes Modell hier steht. Jeder
/// andere Drucker druckt exakt wie bis 1.4.2: keine Abfrage-Verbindung vor
/// dem Bon, kein Takt.
library;

import '../config/model.dart';
import 'kennung.dart' show gleicheKennung;

/// Ein Modell samt Beleg aus dem Gerätetest.
class BewiesenesModell {
  const BewiesenesModell({
    required this.modell,
    required this.geraet,
    required this.datum,
    required this.gemessen,
  });

  /// Modellname, wie `GS I 67` ihn liefert (`TM-T20III`).
  final String modell;

  /// Welches Gerät gemessen wurde (ohne Seriennummer).
  final String geraet;

  /// Tag der Messung (`JJJJ-MM-TT`).
  final String datum;

  /// Was gemessen wurde: Antwort auf `DLE EOT 2/4`, Schweigen mit offenem
  /// Deckel und ohne Papier, Freigabe der Verbindung nach dem Schließen,
  /// Schweigen nach einem langen Bon.
  final String gemessen;
}

/// Die im Gerätetest bewiesenen Modelle. Leer bis zur Messung: ein Eintrag
/// kommt erst, wenn das Modell am Gerät alle Punkte von
/// [BewiesenesModell.gemessen] bestanden hat.
const List<BewiesenesModell> bewieseneModelle = <BewiesenesModell>[];

/// Ob [drucker] ein bewiesenes Modell ist: 9100, Modell über `GS I 67`
/// gelesen und in [liste].
bool modellBewiesen(
  PrinterConfig drucker, {
  List<BewiesenesModell> liste = bewieseneModelle,
}) {
  final modell = drucker.model;
  if (drucker.kind != PrinterKind.tcp9100 ||
      modell == null ||
      drucker.modelSource != KennungsQuelle.escpos) {
    return false;
  }
  return liste.any((m) => gleicheKennung(m.modell, modell));
}
