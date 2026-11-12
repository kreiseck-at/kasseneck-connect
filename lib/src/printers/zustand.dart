/// Papier und Deckel eines Druckers – reine Deutung ohne Netz und Uhr.
///
/// Gedeutet wird nur, was das Gerät plausibel gemeldet hat; alles andere ist
/// unbekannt, und dann wird gedruckt wie bis 1.4.2. Blockiert wird nur bei
/// gemeldetem Papierende oder offenem Deckel, „fast leer“ blockiert nie.
/// Schweigen blockiert nie: es ist nur ein Hinweis
/// ([BereitschaftsHinweis.keineAntwort]).
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
  /// Er hat gültig auf `DLE EOT` geantwortet, ohne Papierende oder offenen
  /// Deckel.
  bereit('ready'),

  /// Er hat gültig geantwortet und selbst Papierende oder offenen Deckel
  /// gemeldet. Nie aus Schweigen: ein Drucker, der schweigt, kann ebenso
  /// gerade einen anderen Rechner bedienen (Gerätetest 12.11.2026).
  nichtBereit('not_ready'),

  unbekannt('unknown');

  const Bereitschaft(this.wireName);

  final String wireName;
}

/// Hinweis zur Bereitschaft (`readinessHint` in der API, nur bei
/// `readiness: unknown`). Die Kasse kann ihn zeigen; einen Bon hält er nie
/// auf.
enum BereitschaftsHinweis {
  /// Ein Drucker, der sonst auf `DLE EOT` antwortet, hat mehrere Abfragen in
  /// Folge nicht beantwortet: Deckel offen oder Papier heraus (TM-T20III
  /// meldet beides nur so) – oder ein anderer Rechner hielt ihn gerade.
  keineAntwort('no_status_answer');

  const BereitschaftsHinweis(this.wireName);

  final String wireName;
}

/// Was der Drucker über Papier, Deckel und Bereitschaft gemeldet hat.
class DruckerZustand {
  const DruckerZustand({
    this.papier = Papier.unbekannt,
    this.deckel = Deckel.unbekannt,
    this.bereitschaft = Bereitschaft.unbekannt,
    this.hinweis,
  });

  static const DruckerZustand unbekannt = DruckerZustand();

  /// Ein statusfähiger Drucker, der mehrmals in Folge nicht geantwortet
  /// hat: unbekannt, mit Hinweis – gedruckt wird wie bis 1.4.2.
  static const DruckerZustand keineAntwort = DruckerZustand(
    hinweis: BereitschaftsHinweis.keineAntwort,
  );

  final Papier papier;
  final Deckel deckel;
  final Bereitschaft bereitschaft;

  /// Hinweis zur unbekannten Bereitschaft; `null`: keiner.
  final BereitschaftsHinweis? hinweis;

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
    // Nur aus einer Antwort des Geräts (siehe [Bereitschaft.nichtBereit]),
    // nie aus Schweigen.
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
      other.bereitschaft == bereitschaft &&
      other.hinweis == hinweis;

  @override
  int get hashCode => Object.hash(papier, deckel, bereitschaft, hinweis);

  @override
  String toString() =>
      'DruckerZustand(${papier.wireName}, ${deckel.wireName}, '
      '${bereitschaft.wireName}${hinweis == null ? '' : ', ${hinweis!.wireName}'})';
}

/// Satz an die Kasse bei Papierende (Spec, Meldungstabelle).
const String paperOutMessage = 'Drucker: Papier leer – neue Rolle einlegen.';

/// Satz an die Kasse bei offenem Deckel.
const String coverOpenMessage = 'Drucker: Deckel offen – bitte schließen.';

/// Satz an die Kasse, wenn der Drucker selbst meldet, dass er nicht bereit
/// ist.
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
    bereitschaft: offline == null && rolle == null
        ? Bereitschaft.unbekannt
        : papier == Papier.leer || deckel == Deckel.offen
        ? Bereitschaft.nichtBereit
        : Bereitschaft.bereit,
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
  final leer = (wert & _asbLeer) != 0;
  final offen = (wert & _asbDeckelOffen) != 0;
  return DruckerZustand(
    bereitschaft: leer || offen
        ? Bereitschaft.nichtBereit
        : Bereitschaft.bereit,
    papier: leer
        ? Papier.leer
        : (wert & _asbFastLeer) != 0
        ? Papier.fastLeer
        : Papier.ok,
    deckel: offen ? Deckel.offen : Deckel.zu,
  );
}
