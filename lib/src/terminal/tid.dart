/// TID-Regeln des Terminals – rein, ohne Netz und Uhr.
///
/// Die Kasse entscheidet genauso (`apps/kasse/src/lib/terminal-suche.ts`,
/// `tidBestaetigt`); beide müssen gleich urteilen.
library;

import '../config/model.dart';

/// „Invalid TID“: gemessen `100108`, laut hobex-Doku `100008`.
const Set<String> ungueltigeTidCodes = <String>{'100108', '100008'};

/// Höchstes Alter einer bestätigten Adresse, auf die Connect einen Aufruf
/// umleitet (Spec 1.3). Ein Tag: die Bestätigung kommt mit jeder Zahlung und
/// Diagnose neu; was älter ist, kann inzwischen einem anderen Gerät gehören.
const Duration umleitungHoechstalter = Duration(hours: 24);

/// TIDs vergleichen wie am Gerät: führende Nullen zählen nicht.
String tidNormal(String tid) {
  final t = tid.trim();
  return RegExp(r'^\d+$').hasMatch(t)
      ? t.replaceFirst(RegExp(r'^0+(?=\d)'), '')
      : t;
}

/// Ob zwei TIDs dieselbe sind.
bool gleicheTid(String a, String b) => tidNormal(a) == tidNormal(b);

/// Bestätigt diese Antwort des Terminals die TID [tid]?
///
/// Nur eine Antwort in HPS-Form (mit `responseCode`), die nicht „Invalid
/// TID“ meldet – und, falls sie eine TID nennt, genau diese. Alles andere
/// bestätigt nichts.
bool tidBestaetigt(Object? antwort, String tid) {
  if (antwort is! Map) return false;
  final code = antwort['responseCode'];
  if (code == null) return false;
  if (ungueltigeTidCodes.contains('$code'.trim())) return false;
  final genannt = antwort['tid'];
  if (genannt != null &&
      '$genannt'.trim().isNotEmpty &&
      !gleicheTid('$genannt', tid)) {
    return false;
  }
  return true;
}

/// Die Adresse, auf die ein Aufruf an [host]:[port] mit [tid] umgeleitet
/// werden darf, nachdem dort keine Verbindung zustande kam; sonst `null`.
///
/// Nur die gemerkte Adresse derselben TID, nur wenn sie eine andere ist und
/// höchstens [umleitungHoechstalter] alt bestätigt wurde.
({String host, int port})? umleitungsZiel({
  required String host,
  required int port,
  required String tid,
  required TerminalConfig? gemerkt,
  required DateTime jetzt,
}) {
  if (gemerkt == null) return null;
  final gemerkteTid = gemerkt.tid;
  final bestaetigt = gemerkt.confirmedAt;
  if (gemerkteTid == null || bestaetigt == null) return null;
  if (!gleicheTid(gemerkteTid, tid)) return null;
  if (gemerkt.host == host && gemerkt.port == port) return null;
  if (gemerkt.host.isEmpty) return null;
  final alter = jetzt.toUtc().difference(bestaetigt.toUtc());
  if (alter.isNegative || alter > umleitungHoechstalter) return null;
  return (host: gemerkt.host, port: gemerkt.port);
}
