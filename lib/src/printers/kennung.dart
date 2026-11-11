/// Kennung eines Druckers – reine Regeln ohne Netz, Datei und Uhr.
///
/// Grundsatz („nie schlechter als 1.4.2“): Eine Abweichung gilt nur als
/// bewiesen, wenn das Gerät unter der Adresse eine ANDERE Seriennummer nennt.
/// Eine andere MAC ist kein Beweis (Drucker wechselt von LAN auf WLAN, ARP
/// nennt den Router) – sie löst nur die Frage nach der Seriennummer aus. Was
/// sich nicht entscheiden lässt, ist unbekannt, und dann wird gedruckt wie
/// bisher.
library;

import '../config/model.dart';

/// So lange gilt eine über Seriennummer oder MAC bestätigte Kennung, ohne
/// dass vor dem nächsten Bon erneut `GS I` gefragt wird. Zehn Minuten: ein
/// Adresswechsel in dieser Zeit fällt trotzdem auf, weil die MAC (ohne Bytes
/// an den Drucker) vor jedem Bon verglichen wird.
const Duration kennungFrisch = Duration(minutes: 10);

/// Wie die gespeicherte MAC zur gesehenen steht.
enum MacVergleich {
  /// Beide bekannt und gleich – derselbe Netzanschluss.
  gleich,

  /// Beide bekannt und verschieden – nur ein Anlass, nachzufragen.
  anders,

  /// Eine Seite fehlt (keine gespeichert, ARP ohne Eintrag, fremdes Netz).
  unbekannt,
}

/// Vergleicht die gespeicherte mit der gesehenen MAC.
MacVergleich vergleicheMac(String? gespeichert, String? gesehen) {
  final a = normalizeMac(gespeichert);
  final b = normalizeMac(gesehen);
  if (a == null || b == null) return MacVergleich.unbekannt;
  return a == b ? MacVergleich.gleich : MacVergleich.anders;
}

/// Was über das Gerät unter der Adresse feststeht.
enum KennungsLage {
  /// Seriennummer oder MAC passen (oder die Bestätigung ist frisch).
  bestaetigt('confirmed'),

  /// Nicht entscheidbar – gedruckt wird wie bis 1.4.2.
  unbekannt('unknown'),

  /// Das Gerät nennt eine andere Seriennummer: bewiesen ein anderer Drucker.
  konflikt('conflict');

  const KennungsLage(this.wireName);

  /// Name im Feld `identity.state` (die einzige Stelle der Abbildung).
  final String wireName;
}

/// Ob vor dem Druck `GS I 68` gefragt werden muss.
///
/// Nur mit gespeicherter Seriennummer; nicht, wenn die MAC passt; nicht, wenn
/// die Kennung frisch bestätigt ist und die MAC nicht widerspricht.
bool seriennummerFragen({
  required String? gespeicherteSerie,
  required MacVergleich mac,
  required bool frisch,
}) {
  if (gespeicherteSerie == null) return false;
  if (mac == MacVergleich.gleich) return false;
  if (frisch && mac == MacVergleich.unbekannt) return false;
  return true;
}

/// Beurteilt die Kennung aus MAC-Vergleich und (falls gefragt) der genannten
/// Seriennummer.
///
/// [geseheneSerie] ist `null`, wenn nicht gefragt wurde oder keine gültige
/// Antwort kam. Nur eine genannte, andere Seriennummer ergibt
/// [KennungsLage.konflikt].
KennungsLage beurteileKennung({
  required String? gespeicherteSerie,
  required MacVergleich mac,
  required String? geseheneSerie,
  required bool frisch,
}) {
  if (gespeicherteSerie != null && geseheneSerie != null) {
    return gleicheKennung(gespeicherteSerie, geseheneSerie)
        ? KennungsLage.bestaetigt
        : KennungsLage.konflikt;
  }
  if (mac == MacVergleich.gleich) return KennungsLage.bestaetigt;
  if (frisch && mac == MacVergleich.unbekannt) return KennungsLage.bestaetigt;
  return KennungsLage.unbekannt;
}

/// Seriennummern und Modelle vergleicht Connect ohne Leerraum und
/// Groß-/Kleinschreibung: dasselbe Gerät nennt sie über mDNS und `GS I` nicht
/// immer gleich geschrieben.
bool gleicheKennung(String a, String b) => _normiert(a) == _normiert(b);

String _normiert(String text) =>
    text.replaceAll(RegExp(r'\s'), '').toUpperCase();

/// Was eine Erkennung über ein Gerät herausgefunden hat.
class ErkannteKennung {
  const ErkannteKennung({
    this.model,
    this.modelQuelle,
    this.serial,
    this.serialQuelle,
    this.mac,
    this.statusfaehigAm,
    this.gsIOhneAntwortAm,
    this.verbunden = false,
  });

  static const ErkannteKennung keine = ErkannteKennung();

  final String? model;
  final KennungsQuelle? modelQuelle;
  final String? serial;
  final KennungsQuelle? serialQuelle;
  final String? mac;

  /// Wann das Gerät gültig auf `DLE EOT` geantwortet hat (`null`: nicht).
  final DateTime? statusfaehigAm;

  /// Wann `GS I 67` ohne gültigen Rahmen blieb (`null`: nicht gefragt oder
  /// beantwortet); siehe `PrinterConfig.idQueryUnansweredAt`.
  final DateTime? gsIOhneAntwortAm;

  /// Ob die Abfrage-Verbindung der Erkennung stand (für die Freigabe der
  /// Verbindung danach; kein Teil der Kennung).
  final bool verbunden;

  bool get leer =>
      model == null &&
      serial == null &&
      mac == null &&
      statusfaehigAm == null &&
      gsIOhneAntwortAm == null;
}

/// Trägt [erkannt] in [drucker] ein – nur, was dort noch fehlt.
///
/// Eine vorhandene Kennung wird nie still überschrieben (ein anderer Drucker
/// unter derselben Adresse soll nicht zum eingerichteten werden). `null`, wenn
/// sich nichts ändert.
PrinterConfig? ergaenzeKennung(
  PrinterConfig drucker,
  ErkannteKennung erkannt,
  DateTime jetzt,
) {
  // Ein über `GS I 67` gelesenes Modell ersetzt eines aus mDNS: nur dieses
  // kann ein bewiesenes sein.
  final ausGsI =
      erkannt.model != null &&
      erkannt.modelQuelle == KennungsQuelle.escpos &&
      drucker.modelSource != KennungsQuelle.escpos;
  final model = ausGsI ? erkannt.model : drucker.model ?? erkannt.model;
  final modelSource = ausGsI
      ? KennungsQuelle.escpos
      : drucker.model != null
      ? drucker.modelSource
      : erkannt.modelQuelle;
  final serial = drucker.serial ?? erkannt.serial;
  final mac = drucker.mac ?? normalizeMac(erkannt.mac);
  final statusfaehig =
      drucker.statusCapableAt ?? erkannt.statusfaehigAm?.toUtc();
  // Ohne `GS I`-Antwort gemerkt, solange kein Modell über `GS I 67` da ist.
  final ohneGsI = modelSource == KennungsQuelle.escpos
      ? drucker.idQueryUnansweredAt
      : drucker.idQueryUnansweredAt ?? erkannt.gsIOhneAntwortAm?.toUtc();
  if (model == drucker.model &&
      modelSource == drucker.modelSource &&
      serial == drucker.serial &&
      mac == drucker.mac &&
      statusfaehig == drucker.statusCapableAt &&
      ohneGsI == drucker.idQueryUnansweredAt) {
    return null;
  }
  final kennungNeu =
      model != drucker.model || serial != drucker.serial || mac != drucker.mac;
  final quelle = serial != null
      ? (drucker.serial != null ? drucker.identitySource : erkannt.serialQuelle)
      : mac != null
      ? KennungsQuelle.arp
      : erkannt.modelQuelle;
  return drucker.copyWith(
    model: model,
    modelSource: modelSource,
    serial: serial,
    mac: mac,
    identifiedAt: kennungNeu ? jetzt : drucker.identifiedAt,
    identitySource: quelle,
    statusCapableAt: statusfaehig,
    idQueryUnansweredAt: ohneGsI,
  );
}

/// Eine Kennung aus den TXT-Einträgen eines mDNS-Dienstes (`schluessel=wert`,
/// je Zeile einer, wie `multicast_dns` sie liefert).
///
/// Modell aus `usb_MDL`, sonst `product` (ohne Klammern), sonst `ty`.
/// Seriennummer nur aus einem ausdrücklich so benannten Eintrag; welche
/// Schlüssel Epson-Drucker setzen, bestätigt der Gerätetest.
ErkannteKennung kennungAusTxt(String txt) {
  final eintraege = <String, String>{};
  for (final zeile in txt.split('\n')) {
    final gleich = zeile.indexOf('=');
    if (gleich <= 0) continue;
    final schluessel = zeile.substring(0, gleich).trim().toLowerCase();
    final wert = _kennungsWert(zeile.substring(gleich + 1));
    if (wert != null) eintraege.putIfAbsent(schluessel, () => wert);
  }
  final product = eintraege['product'];
  final model =
      eintraege['usb_mdl'] ??
      (product == null
          ? null
          : _kennungsWert(product.replaceAll(RegExp(r'[()]'), ''))) ??
      eintraege['ty'];
  String? serial;
  for (final schluessel in _serienSchluessel) {
    serial ??= eintraege[schluessel];
  }
  return ErkannteKennung(
    model: model,
    modelQuelle: model == null ? null : KennungsQuelle.mdns,
    serial: serial,
    serialQuelle: serial == null ? null : KennungsQuelle.mdns,
  );
}

/// TXT-Schlüssel, die eine Seriennummer tragen können (klein geschrieben).
const List<String> _serienSchluessel = <String>[
  'usb_serialnumber',
  'serialnumber',
  'serial',
  'sn',
];

/// Ein brauchbarer Kennungstext: druckbar, nicht leer, nicht zu lang.
String? _kennungsWert(String roh) {
  final text = roh.trim();
  if (text.isEmpty || text.length > kennungsTextMaxLength) return null;
  if (text.codeUnits.any((c) => c < 0x20 || c > 0x7E)) return null;
  return text;
}
