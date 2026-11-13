import 'dart:async';

import '../config/model.dart' show normalizeMac;
import '../log/logger.dart';
import '../printers/discovery.dart' show LocalInterface, subnetOf;
import '../process_runner.dart';

/// So lange gilt eine nachgeschlagene MAC je Adresse (Spec 1.2: 60 s). Jede
/// Abfrage ist ein eigener Prozess (`arp`); vor jedem Bon einen zu starten,
/// kostete Zeit, und binnen einer Minute wechselt kein Drucker die Adresse.
const Duration arpZwischenspeicher = Duration(seconds: 60);

/// Obergrenze für einen `arp`-Aufruf, wenn der Aufrufer keine nennt. `arp -n`
/// liest nur die Tabelle des Rechners und ist in Millisekunden fertig; hängt
/// es (Namensauflösung trotz `-n`), ist die MAC eben unbekannt.
const Duration arpFrist = Duration(seconds: 2);

/// Die MAC zu [ip] aus der Ausgabe eines `arp`-Aufrufs für genau diese
/// Adresse; `null`, wenn dort keine steht.
///
/// - macOS: `? (192.168.0.50) at 0:26:ab:0:0:1 on en0 ifscope [ethernet]`
///   (führende Nullen fehlen), ohne Eintrag `(incomplete)` oder `no entry`.
/// - Linux: Tabellenzeile `192.168.0.50  ether  00:26:ab:00:00:01  C  eth0`.
/// - Windows (`arp -a <ip>`): `192.168.0.50  00-26-ab-00-00-01  dynamic`.
String? macAusArpAusgabe(String ausgabe, String ip) =>
    arpTabelleAusAusgabe(ausgabe)[ip];

final RegExp _macMuster = RegExp(
  r'(?<![0-9A-Fa-f:-])([0-9A-Fa-f]{1,2}[:-]){5}[0-9A-Fa-f]{1,2}(?![0-9A-Fa-f:-])',
);
final RegExp _ipMuster = RegExp(
  r'(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])',
);

/// Alle Zuordnungen Adresse → MAC aus der Ausgabe von `arp -an` (macOS,
/// Linux) bzw. `arp -a` (Windows). Je Zeile zählt die erste IPv4-Adresse und
/// die erste MAC; Zeilen ohne beides (Kopfzeilen, `incomplete`) fallen weg.
Map<String, String> arpTabelleAusAusgabe(String ausgabe) {
  final tabelle = <String, String>{};
  for (final zeile in ausgabe.split('\n')) {
    final ip = _ipMuster.firstMatch(zeile)?.group(1);
    final mac = normalizeMac(_macMuster.firstMatch(zeile)?.group(0));
    if (ip == null || mac == null) continue;
    // Windows nennt in der Kopfzeile die eigene Adresse ohne MAC – fällt oben
    // schon weg. Ein zweiter Eintrag derselben Adresse (zwei Schnittstellen)
    // ändert nichts am ersten.
    tabelle.putIfAbsent(ip, () => mac);
  }
  return tabelle;
}

/// Alle Adressen, unter denen [mac] in [tabelle] steht.
///
/// Steht eine MAC unter mehr als einer Adresse (WLAN-Repeater mit MAC-NAT,
/// Bridge, Router mit Proxy-ARP), kennzeichnet sie kein einzelnes Gerät.
Set<String> adressenMitMac(Map<String, String> tabelle, String? mac) {
  final gesucht = normalizeMac(mac);
  if (gesucht == null) return const <String>{};
  return <String>{
    for (final eintrag in tabelle.entries)
      if (normalizeMac(eintrag.value) == gesucht) eintrag.key,
  };
}

/// Herstellerkennung (OUI, die ersten drei Bytes) von [mac], etwa
/// `00:26:ab`; `null` ohne brauchbare MAC oder bei einer lokal vergebenen
/// (Bit 1 des ersten Bytes): die nennt keinen Hersteller.
String? macHersteller(String? mac) {
  final normiert = normalizeMac(mac);
  if (normiert == null) return null;
  final erstes = int.parse(normiert.substring(0, 2), radix: 16);
  if (erstes & 0x02 != 0) return null;
  return normiert.substring(0, 8);
}

/// Ob [ip] im selben Netz wie eine eigene Schnittstelle liegt.
///
/// Die MAC aus der ARP-Tabelle stimmt nur dort: liegt das Gerät hinter einem
/// Router, kennt der Rechner allenfalls dessen MAC. Dart nennt keine
/// Netzmaske; wie Druckersuche und Netzscan gilt deshalb das /24 einer
/// eigenen Adresse als Netz. Liegt ein Gerät in einem größeren Netz außerhalb
/// davon, wird die MAC eben nicht benutzt – die sichere Richtung.
bool gleichesNetz(String ip, Iterable<LocalInterface> eigene) {
  final netz = subnetOf(ip);
  if (netz == ip) return false;
  return eigene.any((s) => subnetOf(s.address) == netz);
}

/// Liest die ARP-Tabelle des Rechners – mit Zwischenspeicher je Adresse und
/// Zeitgrenze je Aufruf. Wirft nie: was sich nicht lesen lässt, ist unbekannt.
class ArpTabelle {
  ArpTabelle({
    required ProcessStarter start,
    required String betriebssystem,
    AgentLog? log,
    DateTime Function()? clock,
    this.zwischenspeicher = arpZwischenspeicher,
  }) : _start = start,
       _os = betriebssystem,
       _log = log,
       _clock = clock ?? DateTime.now;

  final ProcessStarter _start;
  final String _os;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Wie lange eine nachgeschlagene MAC gilt.
  final Duration zwischenspeicher;

  final Map<String, ({String? mac, DateTime am})> _gemerkt =
      <String, ({String? mac, DateTime am})>{};

  /// Die MAC zu [ip]; `null`, wenn die Tabelle keine nennt oder `arp` nicht
  /// rechtzeitig antwortet.
  Future<String?> macFuer(String ip, {Duration frist = arpFrist}) async {
    final gemerkt = _gemerkt[ip];
    final jetzt = _clock();
    if (gemerkt != null) {
      final alter = jetzt.difference(gemerkt.am);
      if (!alter.isNegative && alter < zwischenspeicher) return gemerkt.mac;
    }
    final argumente = _os == 'windows'
        ? <String>['-a', ip]
        : <String>['-n', ip];
    final ausgabe = await _lies(argumente, frist);
    if (ausgabe == null) return null;
    final mac = macAusArpAusgabe(ausgabe, ip);
    _gemerkt[ip] = (mac: mac, am: jetzt);
    return mac;
  }

  /// Die ganze Tabelle (Adresse → MAC), ohne Zwischenspeicher – fürs
  /// Wiederfinden, das gerade die frischen Einträge braucht.
  Future<Map<String, String>> alle({Duration frist = arpFrist}) async {
    final argumente = _os == 'windows' ? <String>['-a'] : <String>['-an'];
    final ausgabe = await _lies(argumente, frist);
    return ausgabe == null
        ? const <String, String>{}
        : arpTabelleAusAusgabe(ausgabe);
  }

  /// Vergisst die gemerkte MAC zu [ip] (nach einem Adresswechsel).
  void vergiss(String ip) => _gemerkt.remove(ip);

  Future<String?> _lies(List<String> argumente, Duration frist) async {
    final ergebnis = await runWithTimeout(_start, 'arp', argumente, frist);
    if (ergebnis == null) {
      _log?.info('arp ${argumente.join(' ')}: keine Antwort – MAC unbekannt.');
      return null;
    }
    // Ohne Eintrag endet `arp -n` unter macOS mit 1; die Ausgabe ist dann
    // ohne MAC und ergibt ohnehin nichts.
    return '${ergebnis.stdout}';
  }
}
