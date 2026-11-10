/// Papier und Deckel eines Druckers – reine Deutung ohne Netz und Uhr.
///
/// Gedeutet wird nur, was das Gerät plausibel gemeldet hat; alles andere ist
/// unbekannt, und dann wird gedruckt wie bis 1.4.2. Blockiert wird nur bei
/// gemeldetem Papierende oder offenem Deckel, „fast leer“ blockiert nie.
library;

import 'driver.dart';
import 'escpos.dart';

/// Papierstand (`paper` in der API).
enum Papier {
  ok('ok'),
  fastLeer('near_end'),
  leer('out'),
  unbekannt('unknown');

  const Papier(this.wireName);

  /// Name in der API – die einzige Stelle der Abbildung.
  final String wireName;
}

/// Deckel (`cover` in der API).
enum Deckel {
  zu('closed'),
  offen('open'),
  unbekannt('unknown');

  const Deckel(this.wireName);

  final String wireName;
}

/// Ob der Drucker druckbereit ist (`readiness` in der API).
enum Bereitschaft {
  /// Er hat gültig auf `DLE EOT` geantwortet.
  bereit('ready'),

  /// Er hat schon gültig geantwortet und schweigt jetzt: Deckel offen oder
  /// Papier heraus (Gerätetest TM-T20III, ohne Statusbits).
  nichtBereit('not_ready'),

  unbekannt('unknown');

  const Bereitschaft(this.wireName);

  final String wireName;
}

/// Was der Drucker über Papier, Deckel und Bereitschaft gemeldet hat.
class DruckerZustand {
  const DruckerZustand({
    this.papier = Papier.unbekannt,
    this.deckel = Deckel.unbekannt,
    this.bereitschaft = Bereitschaft.unbekannt,
  });

  static const DruckerZustand unbekannt = DruckerZustand();

  /// Ein statusfähiger Drucker, der schweigt.
  static const DruckerZustand nichtBereit = DruckerZustand(
    bereitschaft: Bereitschaft.nichtBereit,
  );

  final Papier papier;
  final Deckel deckel;
  final Bereitschaft bereitschaft;

  /// Der Fehler, mit dem ein Druck vor dem ersten Byte abgelehnt wird; `null`,
  /// wenn gedruckt werden darf.
  ///
  /// Papierende zuerst: wer die Rolle wechselt, hat meist auch den Deckel
  /// offen, und „neue Rolle einlegen“ ist dann die Handlung, die fehlt.
  PrinterFailure? get sperre {
    if (papier == Papier.leer) {
      return const PrinterFailure(errorPaperOut, paperOutMessage);
    }
    if (deckel == Deckel.offen) {
      return const PrinterFailure(errorCoverOpen, coverOpenMessage);
    }
    if (bereitschaft == Bereitschaft.nichtBereit) {
      return const PrinterFailure(errorPrinterNotReady, notReadyMessage);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DruckerZustand &&
      other.papier == papier &&
      other.deckel == deckel &&
      other.bereitschaft == bereitschaft;

  @override
  int get hashCode => Object.hash(papier, deckel, bereitschaft);

  @override
  String toString() =>
      'DruckerZustand(${papier.wireName}, ${deckel.wireName}, '
      '${bereitschaft.wireName})';
}

/// Satz an die Kasse bei Papierende (Spec, Meldungstabelle).
const String paperOutMessage = 'Drucker: Papier leer – neue Rolle einlegen.';

/// Satz an die Kasse bei offenem Deckel.
const String coverOpenMessage = 'Drucker: Deckel offen – bitte schließen.';

/// Satz an die Kasse, wenn ein statusfähiger Drucker schweigt.
const String notReadyMessage =
    'Drucker nicht bereit – Deckel schließen und Papier prüfen.';

// Epson ESC/POS Command Reference, „DLE EOT n“:
// n = 2 (Offline-Grund): Bit 2 = Deckel offen, Bit 5 = Druck wegen
//   Papierende angehalten.
// n = 4 (Rollensensor): Bit 2 und 3 = Papier fast leer, Bit 5 und 6 = Papier
//   leer. Epson setzt beide Bits eines Paares; nur das volle Paar zählt, und
//   „leer“ nur zusammen mit dem Stopp wegen Papierende aus n = 2.
const int _deckelOffen = 0x04;
const int _stoppPapierende = 0x20;
const int _fastLeerPaar = 0x0C;
const int _leerPaar = 0x60;

/// Deutet die Antworten auf `DLE EOT 2` und `DLE EOT 4`.
///
/// Ein Byte ohne die festen Bits (siehe `istEchtzeitStatus`) oder `null` zählt
/// als nicht gemeldet.
DruckerZustand zustandAusDleEot({int? offlineGrund, int? rollensensor}) {
  final offline = offlineGrund != null && istEchtzeitStatus(offlineGrund)
      ? offlineGrund
      : null;
  final rolle = rollensensor != null && istEchtzeitStatus(rollensensor)
      ? rollensensor
      : null;

  final deckel = offline == null
      ? Deckel.unbekannt
      : (offline & _deckelOffen) != 0
      ? Deckel.offen
      : Deckel.zu;

  final Papier papier;
  if (rolle != null) {
    // Papierende sperrt den Druck, deshalb zählt es nur doppelt belegt: der
    // Rollensensor meldet „leer“ UND der Drucker hat deshalb angehalten
    // (`DLE EOT 2`, Bit 5). Ein Byte mit gültigen festen Bits, das zufällig
    // beide Sensorbits trägt, blockiert so keinen Bon.
    papier = (rolle & _leerPaar) == _leerPaar
        ? (offline != null && (offline & _stoppPapierende) != 0
              ? Papier.leer
              : Papier.unbekannt)
        : (rolle & _fastLeerPaar) == _fastLeerPaar
        ? Papier.fastLeer
        : Papier.ok;
  } else if (offline != null && (offline & _stoppPapierende) != 0) {
    papier = Papier.leer;
  } else {
    papier = Papier.unbekannt;
  }
  return DruckerZustand(
    papier: papier,
    deckel: deckel,
    bereitschaft: offline != null || rolle != null
        ? Bereitschaft.bereit
        : Bereitschaft.unbekannt,
  );
}

// Epson ePOS-Print, Attribut `status` der Antwort (ASB-Bits, Epson „ePOS-Print
// XML User's Manual“, Tabelle „status“); die Werte bestätigt der Gerätetest.
const int _asbKeineAntwort = 0x00000001;
const int _asbDeckelOffen = 0x00000020;
const int _asbFastLeer = 0x00020000;
const int _asbLeer = 0x00080000;

/// Deutet das `status`-Attribut einer ePOS-Antwort (Dezimalzahl).
DruckerZustand zustandAusEposStatus(String status) {
  final wert = int.tryParse(status.trim());
  if (wert == null || wert < 0 || (wert & _asbKeineAntwort) != 0) {
    return DruckerZustand.unbekannt;
  }
  return DruckerZustand(
    bereitschaft: Bereitschaft.bereit,
    papier: (wert & _asbLeer) != 0
        ? Papier.leer
        : (wert & _asbFastLeer) != 0
        ? Papier.fastLeer
        : Papier.ok,
    deckel: (wert & _asbDeckelOffen) != 0 ? Deckel.offen : Deckel.zu,
  );
}
