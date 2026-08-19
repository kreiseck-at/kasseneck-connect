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

/// Zeitlimit des gesamten Netzscans über alle Netze hinweg.
///
/// Der Anwender steht vor der Kasse und wartet: lieber ein unvollständiges
/// Ergebnis nach acht Sekunden als ein vollständiges nach dreißig.
const Duration defaultScanBudget = Duration(seconds: 8);

/// Wie viele Adressen gleichzeitig abgeklopft werden.
const int defaultScanConcurrency = 64;

/// Wie viele Netze der Scan höchstens abklopft.
///
/// Auf einem Entwickler- oder Bürorechner hängen schnell fünf bis zehn
/// virtuelle Schnittstellen (Parallels, Docker, VPN); jedes weitere /24
/// kostet Sekunden und bringt fast nie einen Drucker.
const int maxScanInterfaces = 4;

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

/// Eine IPv4-Schnittstelle dieses Rechners, so wie der Netzscan sie braucht.
///
/// Eigener Typ statt [NetworkInterface], weil sich der nicht bauen lässt — mit
/// diesem hier lässt sich die Schnittstellenliste im Test einschieben.
class LocalInterface {
  const LocalInterface({required this.name, required this.address});

  /// Name der Schnittstelle (`en0`, `bridge100`, …).
  final String name;

  /// IPv4-Adresse dieses Rechners auf der Schnittstelle.
  final String address;

  @override
  String toString() => 'LocalInterface($name, $address)';
}

/// Ein abgesuchtes Netz — für die Anzeige in der Kasse („Suche in
/// 192.168.0.0/24 …") und für die Fehlersuche beim Kunden.
class ScannedSubnet {
  const ScannedSubnet({
    required this.interface,
    required this.subnet,
    required this.hosts,
  });

  final String interface;

  /// Netz in Schreibweise `192.168.0.0/24`.
  final String subnet;

  /// Anzahl der eingeplanten Adressen. Bricht das Zeitbudget den Scan ab,
  /// wurden es weniger — die Zahl sagt, wie groß das Netz ist.
  final int hosts;

  Map<String, Object?> toJson() => <String, Object?>{
    'interface': interface,
    'subnet': subnet,
    'hosts': hosts,
  };

  @override
  String toString() => 'ScannedSubnet($interface, $subnet, $hosts)';
}

/// Ergebnis einer Druckersuche: die Treffer und die abgesuchten Netze.
class DiscoveryResult {
  const DiscoveryResult({
    required this.printers,
    this.scanned = const <ScannedSubnet>[],
  });

  final List<DiscoveredPrinter> printers;

  /// Leer, wenn ohne Netzscan gesucht wurde.
  final List<ScannedSubnet> scanned;

  Map<String, Object?> toJson() => <String, Object?>{
    'printers': printers.map((printer) => printer.toJson()).toList(),
    'scanned': scanned.map((subnet) => subnet.toJson()).toList(),
  };
}

/// Sucht die mDNS-Dienste ab.
typedef MdnsProbe = Future<List<DiscoveredPrinter>> Function(Duration timeout);

/// Liefert die IPv4-Schnittstellen dieses Rechners.
typedef InterfaceProbe = Future<List<LocalInterface>> Function();

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
    InterfaceProbe? interfaces,
    TcpProbe? tcp,
    this.mdnsTimeout = defaultMdnsTimeout,
    this.scanTimeout = defaultScanTimeout,
    this.scanBudget = defaultScanBudget,
    this.scanConcurrency = defaultScanConcurrency,
    this.scanPort = rawPrintPort,
  }) : _log = log,
       _mdns = mdns,
       _interfaces = interfaces,
       _tcp = tcp ?? tcpReachable;

  final AgentLog? _log;
  final MdnsProbe? _mdns;
  final InterfaceProbe? _interfaces;
  final TcpProbe _tcp;

  /// Zeitlimit der mDNS-Suche insgesamt.
  final Duration mdnsTimeout;

  /// Zeitlimit je Adresse beim Netzscan.
  final Duration scanTimeout;

  /// Zeitlimit des gesamten Netzscans.
  final Duration scanBudget;

  /// Wie viele Adressen gleichzeitig abgeklopft werden.
  final int scanConcurrency;

  /// Port, den der Netzscan abklopft (im Betrieb immer [rawPrintPort]).
  final int scanPort;

  /// Sucht Drucker; [scan] schaltet den Netzscan zu (dauert spürbar länger).
  ///
  /// Wirft nie: ohne Netz, ohne Multicast-Recht oder ohne passendes Interface
  /// kommt eine leere Liste zurück — die Kasse zeigt dann „nichts gefunden"
  /// und der Anwender trägt die Adresse von Hand ein.
  Future<DiscoveryResult> discover({bool scan = false}) async {
    final found = <DiscoveredPrinter>[];
    final scanned = <ScannedSubnet>[];

    // Doppelt gedeckelt: die echte mDNS-Suche hält ihr Limit selbst ein und
    // behält dabei, was schon da ist. Bleibt sie trotzdem stehen (kaputter
    // Multicast-Socket hinter einem VPN), zieht dieses Limit die Notbremse —
    // sonst käme der Netzscan gar nicht mehr dran.
    found.addAll(
      await _guard(
        'mDNS',
        () => _mdnsPass().timeout(
          mdnsTimeout + const Duration(milliseconds: 500),
          onTimeout: () => const <DiscoveredPrinter>[],
        ),
      ),
    );

    if (scan) {
      found.addAll(await _guard('Netzscan', () => _scanLocalNetworks(scanned)));
    }

    final unique = <String, DiscoveredPrinter>{};
    for (final printer in found) {
      unique.putIfAbsent(printer.key, () => printer);
    }
    return DiscoveryResult(printers: unique.values.toList(), scanned: scanned);
  }

  /// Ein mDNS-Durchgang, verpackt in eine eigene `async`-Funktion.
  ///
  /// Die Verpackung ist nicht kosmetisch: `Future.timeout` prüft `onTimeout`
  /// gegen den **Laufzeit**-Typ des Futures. Eine eingeschobene Suche kann
  /// einen engeren Typ liefern (`Future<Never>`), und `.timeout` darauf fiele
  /// mit einem Typfehler um, statt das Zeitlimit zu ziehen. Das `async` hier
  /// stellt sicher, dass der Typ immer `Future<List<DiscoveredPrinter>>` ist.
  Future<List<DiscoveredPrinter>> _mdnsPass() async =>
      (_mdns ?? _lookupMdns)(mdnsTimeout);

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
  ///
  /// [timeout] gilt für den gesamten Vorgang, das Öffnen des Multicast-Sockets
  /// eingeschlossen: genau dort bleibt die Suche hängen, wenn ein VPN oder
  /// eine Firewall Multicast verbietet.
  Future<List<DiscoveredPrinter>> _lookupMdns(Duration timeout) async {
    final client = MDnsClient();
    final found = <DiscoveredPrinter>[];
    final clock = Stopwatch()..start();
    try {
      await client.start().timeout(timeout);
      final left = timeout - clock.elapsed;
      if (left > Duration.zero) {
        await _collectMdns(client, found, left).timeout(left, onTimeout: () {});
      }
    } on Object catch (e) {
      _log?.warn('mDNS nicht verfügbar: $e');
    } finally {
      try {
        client.stop();
      } on Object catch (e) {
        _log?.warn('mDNS ließ sich nicht sauber schließen: $e');
      }
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

  /// Netzscan über **jedes** brauchbare /24 dieses Rechners.
  ///
  /// Bewusst nicht nur über das erste: auf einem Rechner mit Parallels, Docker
  /// oder VPN steht das WLAN-Interface nicht zwingend vorn, und ein Scan im
  /// Netz einer virtuellen Maschine findet nie einen Drucker. Die abgesuchten
  /// Netze landen in [report], damit die Kasse zeigen kann, wo gesucht wurde.
  Future<List<DiscoveredPrinter>> _scanLocalNetworks(
    List<ScannedSubnet> report,
  ) async {
    final interfaces = scanInterfaces(
      await (_interfaces ?? listLocalIpv4Interfaces)(),
    );
    if (interfaces.isEmpty) {
      _log?.warn('Netzscan übersprungen: kein brauchbares IPv4-Netz gefunden.');
      return const <DiscoveredPrinter>[];
    }

    final found = <DiscoveredPrinter>[];
    final clock = Stopwatch()..start();
    for (final interface in interfaces) {
      final hosts = subnetHosts(interface.address);
      report.add(
        ScannedSubnet(
          interface: interface.name,
          subnet: subnetOf(interface.address),
          hosts: hosts.length,
        ),
      );

      final left = scanBudget - clock.elapsed;
      if (left <= Duration.zero) {
        _log?.warn(
          'Netzscan abgebrochen: Zeitbudget vor ${interface.name} aufgebraucht.',
        );
        break;
      }

      found.addAll(
        await scanSubnet(
          hosts: hosts,
          port: scanPort,
          timeout: scanTimeout,
          concurrency: scanConcurrency,
          budget: left,
          probe: _tcp,
        ),
      );
    }
    return found;
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

/// Alle IPv4-Adressen dieses Rechners samt Schnittstellennamen (ohne
/// Loopback).
Future<List<LocalInterface>> listLocalIpv4Interfaces() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  return <LocalInterface>[
    for (final interface in interfaces)
      for (final address in interface.addresses)
        LocalInterface(name: interface.name, address: address.address),
  ];
}

/// Wählt aus, welche Netze der Scan abklopft.
///
/// Draußen bleiben die Selbstvergabe-Adressen (169.254.x — dort steht nie ein
/// eingerichteter Drucker) und krumme Adressen. Zwei Schnittstellen im selben
/// /24 ergeben einen Scan, und mehr als [max] Netze werden nicht abgesucht.
///
/// Loopback wird hier bewusst **nicht** aussortiert: die echte Quelle
/// [listLocalIpv4Interfaces] liefert es gar nicht erst, und so kann ein Test
/// das Loopback-Netz einschieben und gegen einen wirklich lauschenden Port
/// scannen.
List<LocalInterface> scanInterfaces(
  List<LocalInterface> all, {
  int max = maxScanInterfaces,
}) {
  final chosen = <LocalInterface>[];
  final seen = <String>{};
  for (final interface in all) {
    final address = interface.address;
    if (subnetHosts(address).isEmpty) continue;
    if (address.startsWith('169.254.')) continue;
    if (!seen.add(subnetOf(address))) continue;
    chosen.add(interface);
    if (chosen.length >= max) break;
  }
  return chosen;
}

/// Das /24 zu einer Adresse in Schreibweise `192.168.0.0/24`.
///
/// Eine unbrauchbare Adresse kommt unverändert zurück — der Wert steht nur im
/// Bericht, er darf die Suche nicht kippen.
String subnetOf(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return address;
  return '${parts.take(3).join('.')}.0/24';
}

/// Alle fremden Adressen des /24 zu [address] (ohne Netz, Broadcast und die
/// eigene Adresse).
List<String> subnetHosts(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return const <String>[];
  final prefix = parts.take(3).join('.');
  final own = int.tryParse(parts[3]);
  if (own == null) return const <String>[];

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
///
/// [budget] deckelt den ganzen Durchlauf. Läuft es ab, hören die Arbeiter auf
/// — was bis dahin gefunden wurde, bleibt im Ergebnis: ein Drucker, der nach
/// sechs Sekunden auftaucht, ist mehr wert als ein Abbruch mit leerer Liste.
Future<List<DiscoveredPrinter>> scanSubnet({
  required List<String> hosts,
  int port = rawPrintPort,
  Duration timeout = defaultScanTimeout,
  int concurrency = defaultScanConcurrency,
  Duration? budget,
  TcpProbe probe = tcpReachable,
}) async {
  final reachable = <String>{};
  final clock = Stopwatch()..start();
  var next = 0;

  Future<void> worker() async {
    while (true) {
      if (next >= hosts.length) return;
      if (budget != null && clock.elapsed >= budget) return;
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
