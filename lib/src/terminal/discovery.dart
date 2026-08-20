import 'dart:async';

import '../log/logger.dart';
import '../printers/discovery.dart'
    show
        LocalInterface,
        ScannedSubnet,
        listLocalIpv4Interfaces,
        scanInterfaces,
        scanSubnet,
        subnetHosts,
        subnetOf;
import 'hps.dart';

/// Zeitbudget der ganzen Terminal-Suche (alle Netze zusammen).
const Duration terminalScanBudget = Duration(seconds: 12);

/// Zeitlimit je Adresse beim Abklopfen von Port 8080.
const Duration terminalScanTimeout = Duration(milliseconds: 300);

/// Zeitlimit für die Nachfrage `GET /api/terminals` je Kandidat.
///
/// Auf Port 8080 lauscht auf fremden Geräten alles Mögliche (Router-UIs,
/// Kameras, Entwicklungs-Server) — erst diese Nachfrage macht aus einem
/// offenen Port ein Hobex-Terminal.
const Duration terminalVerifyTimeout = Duration(seconds: 3);

/// Ein gefundenes HPS-Terminal: Adresse plus die TIDs, die es selbst nennt.
class DiscoveredTerminal {
  DiscoveredTerminal({
    required this.host,
    required this.port,
    required this.tids,
  });

  final String host;
  final int port;
  final List<String> tids;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'port': port,
    'tids': tids,
  };
}

/// Ergebnis der Terminal-Suche (Treffer + abgesuchte Netze, wie beim Drucker).
class TerminalDiscoveryResult {
  TerminalDiscoveryResult({required this.found, required this.scanned});

  final List<DiscoveredTerminal> found;
  final List<ScannedSubnet> scanned;

  Map<String, Object?> toJson() => <String, Object?>{
    'found': found.map((t) => t.toJson()).toList(),
    'scanned': scanned.map((s) => s.toJson()).toList(),
  };
}

/// Sucht Hobex-HPS-Terminals im Kassen-Netz.
///
/// Zwei Stufen: erst zählt der TCP-Scan die Adressen mit offenem Port 8080
/// auf (gleiches Verfahren wie die Druckersuche auf 9100), dann fragt
/// `GET /api/terminals` nach — nur wer darauf mit einer Terminal-Liste
/// antwortet, ist ein Treffer.
Future<TerminalDiscoveryResult> discoverTerminals({
  required HpsBridge bridge,
  AgentLog? log,
  Future<List<LocalInterface>> Function() interfaces = listLocalIpv4Interfaces,
  // Nur für Tests: die echte Suche klopft immer den HPS-Port 8080 ab.
  int port = hpsDefaultPort,
}) async {
  final report = <ScannedSubnet>[];
  final treffer = <DiscoveredTerminal>[];
  final netze = scanInterfaces(await interfaces());
  if (netze.isEmpty) {
    log?.warn('Terminal-Suche übersprungen: kein brauchbares IPv4-Netz.');
    return TerminalDiscoveryResult(found: treffer, scanned: report);
  }

  final clock = Stopwatch()..start();
  for (final netz in netze) {
    final hosts = subnetHosts(netz.address);
    report.add(
      ScannedSubnet(
        interface: netz.name,
        subnet: subnetOf(netz.address),
        hosts: hosts.length,
      ),
    );
    final left = terminalScanBudget - clock.elapsed;
    if (left <= Duration.zero) break;

    final offen = await scanSubnet(
      hosts: hosts,
      port: port,
      timeout: terminalScanTimeout,
      budget: left,
    );
    for (final kandidat in offen) {
      if (await _istHps(bridge, kandidat.host, port)) {
        treffer.add(
          DiscoveredTerminal(
            host: kandidat.host,
            port: port,
            // Die TID kennt nur der Vertrag (bzw. eine Diagnose MIT TID) —
            // die TID-lose Probe liefert sie nicht.
            tids: const <String>[],
          ),
        );
      }
    }
  }
  log?.info(
    'Terminal-Suche fertig: ${treffer.length} Treffer in '
    '${report.length} Netz(en).',
  );
  return TerminalDiscoveryResult(found: treffer, scanned: report);
}

/// Ist der Kandidat ein HPS? Die TID-lose Probe entscheidet: das echte
/// Terminal antwortet mit HTTP 200 und `responseCode` („Invalid TID“) —
/// fremde 8080-Dienste antworten anders oder gar nicht.
Future<bool> _istHps(HpsBridge bridge, String host, int port) async {
  try {
    final antwort = await bridge
        .probe(host: host, port: port)
        .timeout(terminalVerifyTimeout);
    return siehtNachHpsAus(antwort);
  } on HpsWegFehler {
    return false;
  } on TimeoutException {
    return false;
  }
}
