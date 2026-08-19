import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import '../config/model.dart';
import '../log/logger.dart';

/// Dienste, unter denen sich Netzwerkdrucker im LAN melden.
const List<String> printerServices = <String>[
  '_printer._tcp.local',
  '_pdl-datastream._tcp.local',
  '_epos._tcp.local',
];

/// Zeitlimit der mDNS-Suche.
const Duration defaultMdnsTimeout = Duration(seconds: 3);

/// Port, den der Netzscan abklopft.
const int rawPrintPort = 9100;

/// Zeitlimit je Adresse beim Netzscan.
const Duration defaultScanTimeout = Duration(milliseconds: 300);

/// Wie viele Adressen gleichzeitig abgeklopft werden.
const int defaultScanConcurrency = 64;

/// Ein gefundener Drucker (noch nicht konfiguriert).
class DiscoveredPrinter {
  const DiscoveredPrinter({
    required this.host,
    required this.port,
    required this.kind,
    this.name,
  });

  final String host;
  final int port;
  final PrinterKind kind;

  /// Anzeigename aus mDNS; beim Netzscan gibt es keinen.
  final String? name;

  /// Schlüssel für die Doppelbereinigung.
  String get key => '$host:$port';

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'port': port,
    if (name != null) 'name': name,
    'kind': kind.wireName,
  };

  @override
  String toString() => 'DiscoveredPrinter($host:$port, ${kind.wireName})';
}

/// Sucht die mDNS-Dienste ab.
typedef MdnsProbe = Future<List<DiscoveredPrinter>> Function(Duration timeout);

/// Klopft das lokale /24 ab.
typedef ScanProbe = Future<List<DiscoveredPrinter>> Function();

/// Prüft, ob an einer Adresse ein TCP-Port offen ist.
typedef TcpProbe =
    Future<bool> Function(String host, int port, Duration timeout);

/// Findet Netzwerkdrucker: erst per mDNS, auf Wunsch zusätzlich per Netzscan.
///
/// Beide Wege sind über den Konstruktor austauschbar — in Tests läuft weder
/// echtes mDNS noch ein echter Scan.
class PrinterDiscovery {
  PrinterDiscovery({
    AgentLog? log,
    MdnsProbe? mdns,
    ScanProbe? scan,
    this.mdnsTimeout = defaultMdnsTimeout,
  }) : _log = log,
       _mdns = mdns,
       _scan = scan;

  final AgentLog? _log;
  final MdnsProbe? _mdns;
  final ScanProbe? _scan;

  /// Zeitlimit der mDNS-Suche insgesamt.
  final Duration mdnsTimeout;

  /// Sucht Drucker; [scan] schaltet den Netzscan zu (dauert spürbar länger).
  ///
  /// Wirft nie: ohne Netz, ohne Multicast-Recht oder ohne passendes Interface
  /// kommt eine leere Liste zurück — die Kasse zeigt dann „nichts gefunden"
  /// und der Anwender trägt die Adresse von Hand ein.
  Future<List<DiscoveredPrinter>> discover({bool scan = false}) async {
    final found = <DiscoveredPrinter>[];
    found.addAll(
      await _guard('mDNS', () => (_mdns ?? _lookupMdns)(mdnsTimeout)),
    );
    if (scan) {
      found.addAll(await _guard('Netzscan', _scan ?? _scanLocalNetwork));
    }

    final unique = <String, DiscoveredPrinter>{};
    for (final printer in found) {
      unique.putIfAbsent(printer.key, () => printer);
    }
    return unique.values.toList();
  }

  Future<List<DiscoveredPrinter>> _guard(
    String what,
    Future<List<DiscoveredPrinter>> Function() probe,
  ) async {
    try {
      return await probe();
    } on Object catch (e) {
      _log?.warn('Druckersuche ($what) fehlgeschlagen: $e');
      return const <DiscoveredPrinter>[];
    }
  }

  /// Echte mDNS-Suche über alle [printerServices].
  Future<List<DiscoveredPrinter>> _lookupMdns(Duration timeout) async {
    final client = MDnsClient();
    final found = <DiscoveredPrinter>[];
    try {
      await client.start();
      // Ein Zeitlimit für die gesamte Suche: die drei Dienste nacheinander mit
      // je 3 s wären dem Anwender zu lang. Was bis dahin da ist, zählt.
      await _collectMdns(
        client,
        found,
        timeout,
      ).timeout(timeout, onTimeout: () {});
    } on Object catch (e) {
      _log?.warn('mDNS nicht verfügbar: $e');
    } finally {
      client.stop();
    }
    return found;
  }

  Future<void> _collectMdns(
    MDnsClient client,
    List<DiscoveredPrinter> found,
    Duration timeout,
  ) async {
    for (final service in printerServices) {
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(service),
        timeout: timeout,
      )) {
        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: timeout,
        )) {
          found.add(
            DiscoveredPrinter(
              host: await _addressOf(client, srv.target, timeout),
              port: srv.port,
              kind: kindForService(service),
              name: serviceLabel(ptr.domainName, service),
            ),
          );
        }
      }
    }
  }

  /// Löst den Hostnamen auf; ohne Antwort bleibt der Name stehen.
  Future<String> _addressOf(
    MDnsClient client,
    String target,
    Duration timeout,
  ) async {
    await for (final ip in client.lookup<IPAddressResourceRecord>(
      ResourceRecordQuery.addressIPv4(target),
      timeout: timeout,
    )) {
      return ip.address.address;
    }
    return target;
  }

  /// Netzscan über das /24 der ersten echten IPv4-Adresse.
  Future<List<DiscoveredPrinter>> _scanLocalNetwork() async {
    final address = await firstLocalIpv4();
    if (address == null) {
      _log?.warn('Netzscan übersprungen: kein IPv4-Interface gefunden.');
      return const <DiscoveredPrinter>[];
    }
    return scanSubnet(hosts: subnetHosts(address));
  }
}

/// Ordnet einen mDNS-Dienst der Anbindungsart zu.
PrinterKind kindForService(String service) =>
    service.startsWith('_epos.') ? PrinterKind.epos : PrinterKind.tcp9100;

/// Schneidet den Dienstnamen vom Instanznamen ab
/// (`TM-T20._printer._tcp.local` → `TM-T20`).
String? serviceLabel(String domainName, String service) {
  final suffix = '.$service';
  if (!domainName.endsWith(suffix)) {
    return domainName.isEmpty ? null : domainName;
  }
  final label = domainName.substring(0, domainName.length - suffix.length);
  return label.isEmpty ? null : label;
}

/// Erste nicht-lokale IPv4-Adresse dieses Rechners.
Future<String?> firstLocalIpv4() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address.address;
    }
  }
  return null;
}

/// Alle fremden Adressen des /24 zu [address] (ohne Netz, Broadcast und die
/// eigene Adresse).
List<String> subnetHosts(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return const <String>[];
  final prefix = parts.take(3).join('.');
  final own = int.tryParse(parts[3]);

  final hosts = <String>[];
  for (var i = 1; i <= 254; i++) {
    if (i == own) continue;
    hosts.add('$prefix.$i');
  }
  return hosts;
}

/// Klopft [hosts] auf einen offenen Druckport ab.
///
/// Die Reihenfolge des Ergebnisses folgt [hosts]; gleichzeitig laufen
/// höchstens [concurrency] Verbindungen, sonst quittiert das Betriebssystem
/// den Dienst („too many open files").
Future<List<DiscoveredPrinter>> scanSubnet({
  required List<String> hosts,
  int port = rawPrintPort,
  Duration timeout = defaultScanTimeout,
  int concurrency = defaultScanConcurrency,
  TcpProbe probe = tcpReachable,
}) async {
  final reachable = <String>{};
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (next >= hosts.length) return;
      final host = hosts[next++];
      if (await probe(host, port, timeout)) reachable.add(host);
    }
  }

  final workers = concurrency < hosts.length ? concurrency : hosts.length;
  await Future.wait(List<Future<void>>.generate(workers, (_) => worker()));

  return hosts
      .where(reachable.contains)
      .map(
        (host) => DiscoveredPrinter(
          host: host,
          port: port,
          kind: PrinterKind.tcp9100,
        ),
      )
      .toList();
}

/// Prüft, ob sich an [host]:[port] eine TCP-Verbindung aufbauen lässt.
Future<bool> tcpReachable(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}
