import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:test/test.dart';

void main() {
  _txtTests();
  DiscoveredPrinter found(
    String host, {
    int port = 9100,
    String? name,
    PrinterKind kind = PrinterKind.tcp9100,
  }) => DiscoveredPrinter(host: host, port: port, name: name, kind: kind);

  /// Eine Suche, deren Netzscan über die eingebaute Maschinerie läuft, aber
  /// weder echte Schnittstellen noch echte Verbindungen benutzt.
  PrinterDiscovery withNetwork({
    required List<LocalInterface> interfaces,
    required Set<String> reachable,
    MdnsProbe? mdns,
    Duration? scanBudget,
    Duration? mdnsTimeout,
  }) => PrinterDiscovery(
    mdns: mdns ?? (_) async => const <DiscoveredPrinter>[],
    interfaces: () async => interfaces,
    tcp: (host, port, timeout) async => reachable.contains(host),
    scanBudget: scanBudget ?? defaultScanBudget,
    mdnsTimeout: mdnsTimeout ?? defaultMdnsTimeout,
  );

  group('Suche', () {
    test('ohne Scan wird nur mDNS befragt', () async {
      var scanned = false;
      final discovery = PrinterDiscovery(
        mdns: (_) async => <DiscoveredPrinter>[
          found('192.168.0.50', name: 'TM-T20'),
        ],
        interfaces: () async {
          scanned = true;
          return const <LocalInterface>[];
        },
      );

      final result = await discovery.discover();

      expect(scanned, isFalse);
      expect(result.scanned, isEmpty);
      expect(result.printers.single.toJson(), <String, Object?>{
        'host': '192.168.0.50',
        'port': 9100,
        'name': 'TM-T20',
        'kind': 'tcp9100',
      });
    });

    test('mit Scan werden beide Quellen zusammengeführt', () async {
      final discovery = withNetwork(
        mdns: (_) async => <DiscoveredPrinter>[
          found('192.168.0.50', name: 'TM-T20'),
        ],
        interfaces: const <LocalInterface>[
          LocalInterface(name: 'en0', address: '192.168.0.54'),
        ],
        reachable: <String>{'192.168.0.50', '192.168.0.77'},
      );

      final result = await discovery.discover(scan: true);

      expect(result.printers.map((e) => e.host), <String>[
        '192.168.0.50',
        '192.168.0.77',
      ]);
      expect(result.printers.first.name, 'TM-T20', reason: 'Name aus mDNS');
    });

    test('derselbe Host mit anderem Port bleibt ein eigener Treffer', () async {
      final discovery = PrinterDiscovery(
        mdns: (_) async => <DiscoveredPrinter>[
          found('192.168.0.50', port: 80, kind: PrinterKind.epos),
          found('192.168.0.50'),
        ],
      );

      expect((await discovery.discover()).printers, hasLength(2));
    });

    test(
      'eine kaputte Suche liefert eine leere Liste statt eines Fehlers',
      () async {
        final discovery = PrinterDiscovery(
          mdns: (_) async => throw StateError('kein Netz'),
          interfaces: () async => throw StateError('kein Interface'),
        );

        final result = await discovery.discover(scan: true);

        expect(result.printers, isEmpty);
        expect(result.scanned, isEmpty);
      },
    );

    test('ein hängendes mDNS hält den Netzscan nicht auf', () async {
      final discovery = withNetwork(
        mdns: (_) => Completer<List<DiscoveredPrinter>>().future,
        interfaces: const <LocalInterface>[
          LocalInterface(name: 'en0', address: '192.168.0.54'),
        ],
        reachable: <String>{'192.168.0.136'},
        // Kurzes mDNS-Limit, damit der Test nicht drei Sekunden steht.
        mdnsTimeout: const Duration(milliseconds: 50),
      );

      final result = await discovery
          .discover(scan: true)
          .timeout(const Duration(seconds: 5));

      expect(result.printers.map((e) => e.host), <String>['192.168.0.136']);
    });
  });

  group('Netzsuche', () {
    test('das /24 umfasst 253 fremde Adressen ohne Netz und Broadcast', () {
      final hosts = subnetHosts('192.168.0.50');

      expect(hosts, hasLength(253));
      expect(hosts.first, '192.168.0.1');
      expect(hosts.last, '192.168.0.254');
      expect(hosts, isNot(contains('192.168.0.0')));
      expect(hosts, isNot(contains('192.168.0.50')));
      expect(hosts, isNot(contains('192.168.0.255')));
    });

    test('das Netz einer Adresse wird als /24 benannt', () {
      expect(subnetOf('192.168.0.54'), '192.168.0.0/24');
      expect(subnetOf('10.211.55.2'), '10.211.55.0/24');
      expect(subnetOf('krumm'), 'krumm');
    });

    test('scannt jede Adresse und meldet nur die erreichbaren', () async {
      final probed = <String>[];
      final result = await scanSubnet(
        hosts: subnetHosts('10.0.0.5'),
        probe: (host, port, timeout) async {
          probed.add(host);
          expect(port, 9100);
          expect(timeout, const Duration(milliseconds: 300));
          return host == '10.0.0.9' || host == '10.0.0.200';
        },
      );

      expect(probed, hasLength(253));
      expect(result.map((e) => e.host), <String>['10.0.0.9', '10.0.0.200']);
      expect(result.first.port, 9100);
      expect(result.first.kind, PrinterKind.tcp9100);
    });

    test('höchstens 64 Adressen gleichzeitig', () async {
      var running = 0;
      var peak = 0;
      await scanSubnet(
        hosts: subnetHosts('10.0.0.5'),
        probe: (host, port, timeout) async {
          running++;
          peak = running > peak ? running : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          running--;
          return false;
        },
      );

      expect(peak, 64);
    });

    test('das Zeitbudget bricht ab, behält aber das schon Gefundene', () async {
      final result = await scanSubnet(
        hosts: subnetHosts('10.0.0.5'),
        concurrency: 1,
        budget: const Duration(milliseconds: 60),
        probe: (host, port, timeout) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return host == '10.0.0.1';
        },
      );

      expect(result.map((e) => e.host), <String>['10.0.0.1']);
    });
  });

  group('Schnittstellenwahl', () {
    LocalInterface iface(String name, String address) =>
        LocalInterface(name: name, address: address);

    test('alle echten IPv4-Netze werden gescannt, nicht nur das erste', () {
      final chosen = scanInterfaces(<LocalInterface>[
        iface('en0', '192.168.0.54'),
        iface('bridge100', '10.211.55.2'),
        iface('bridge101', '10.37.129.2'),
      ]);

      expect(chosen.map((e) => e.address), <String>[
        '192.168.0.54',
        '10.211.55.2',
        '10.37.129.2',
      ]);
    });

    test('die Selbstvergabe-Adressen (169.254.x) fallen weg', () {
      final chosen = scanInterfaces(<LocalInterface>[
        iface('en1', '169.254.13.7'),
        iface('en0', '192.168.0.54'),
      ]);

      expect(chosen.map((e) => e.name), <String>['en0']);
    });

    test('die echte Quelle liefert kein Loopback', () async {
      final all = await listLocalIpv4Interfaces();

      expect(all.map((e) => e.address), isNot(contains('127.0.0.1')));
    });

    test('zwei Schnittstellen im selben /24 ergeben einen Scan', () {
      final chosen = scanInterfaces(<LocalInterface>[
        iface('en0', '192.168.0.54'),
        iface('en1', '192.168.0.55'),
      ]);

      expect(chosen, hasLength(1));
      expect(chosen.single.name, 'en0');
    });

    test('höchstens vier Netze, sonst dauert die Suche zu lang', () {
      final chosen = scanInterfaces(<LocalInterface>[
        for (var i = 1; i <= 9; i++) iface('en$i', '10.0.$i.5'),
      ]);

      expect(chosen, hasLength(maxScanInterfaces));
      expect(maxScanInterfaces, 4);
    });

    test('unbrauchbare Adressen werden übergangen', () {
      expect(scanInterfaces(<LocalInterface>[iface('en0', 'krumm')]), isEmpty);
    });
  });

  group('Scanbericht', () {
    test('der Bericht nennt Schnittstelle, Netz und Adressanzahl', () async {
      final discovery = withNetwork(
        interfaces: const <LocalInterface>[
          LocalInterface(name: 'en0', address: '192.168.0.54'),
          LocalInterface(name: 'bridge100', address: '10.211.55.2'),
        ],
        reachable: <String>{'192.168.0.136'},
      );

      final result = await discovery.discover(scan: true);

      expect(result.printers.single.host, '192.168.0.136');
      expect(result.scanned.map((e) => e.toJson()), <Map<String, Object?>>[
        <String, Object?>{
          'interface': 'en0',
          'subnet': '192.168.0.0/24',
          'hosts': 253,
        },
        <String, Object?>{
          'interface': 'bridge100',
          'subnet': '10.211.55.0/24',
          'hosts': 253,
        },
      ]);
    });

    test(
      'der Drucker im zweiten Netz wird gefunden, nicht nur im ersten',
      () async {
        final discovery = withNetwork(
          interfaces: const <LocalInterface>[
            LocalInterface(name: 'bridge100', address: '10.211.55.2'),
            LocalInterface(name: 'en0', address: '192.168.0.54'),
          ],
          reachable: <String>{'192.168.0.136'},
        );

        final result = await discovery.discover(scan: true);

        expect(result.printers.single.host, '192.168.0.136');
        expect(result.printers.single.port, 9100);
      },
    );

    test('ohne brauchbare Schnittstelle bleibt der Bericht leer', () async {
      final discovery = withNetwork(
        interfaces: const <LocalInterface>[
          LocalInterface(name: 'en1', address: '169.254.13.7'),
        ],
        reachable: <String>{},
      );

      final result = await discovery.discover(scan: true);

      expect(result.printers, isEmpty);
      expect(result.scanned, isEmpty);
    });
  });

  test('Dienstnamen ergeben die Anbindungsart', () {
    expect(kindForService('_epos._tcp.local'), PrinterKind.epos);
    expect(kindForService('_printer._tcp.local'), PrinterKind.tcp9100);
    expect(kindForService('_pdl-datastream._tcp.local'), PrinterKind.tcp9100);
    expect(printerServices, hasLength(3));
  });
}

/// mDNS ohne Netz: ein Drucker unter `_pdl-datastream`, der auf die
/// TXT-Abfrage nie antwortet. Schreibt jede Abfrage samt Frist mit.
class _StilleTxtMdns extends MDnsClient {
  final List<(int, Duration)> anfragen = <(int, Duration)>[];

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {}

  @override
  void stop() {}

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    anfragen.add((query.resourceRecordType, timeout));
    final antwort = switch (query.resourceRecordType) {
      ResourceRecordType.serverPointer
          when query.fullyQualifiedName == '_pdl-datastream._tcp.local' =>
        const PtrResourceRecord(
          '_pdl-datastream._tcp.local',
          0,
          domainName: 'Bon._pdl-datastream._tcp.local',
        ),
      ResourceRecordType.service => const SrvResourceRecord(
        'Bon._pdl-datastream._tcp.local',
        0,
        target: 'bon.local',
        port: 9100,
        priority: 0,
        weight: 0,
      ),
      ResourceRecordType.addressIPv4 => IPAddressResourceRecord(
        'bon.local',
        0,
        address: InternetAddress('192.168.0.50'),
      ),
      _ => null,
    };
    if (antwort != null) return Stream<T>.value(antwort as T);
    // TXT: keine Antwort bis zur Frist.
    return _bisZurFrist<T>(
      query.resourceRecordType == ResourceRecordType.text
          ? timeout
          : Duration.zero,
    );
  }

  static Stream<T> _bisZurFrist<T>(Duration frist) async* {
    await Future<void>.delayed(frist);
  }
}

void _txtTests() {
  group('TXT-Abfrage der Suche', () {
    test('eigene kurze Frist: ein Drucker ohne TXT hält die Suche nicht bis '
        'zum Ende der mDNS-Frist auf', () async {
      final mdns = _StilleTxtMdns();
      final suche = PrinterDiscovery(
        mdnsClient: () => mdns,
        mdnsTimeout: const Duration(hours: 1),
      );
      final ergebnis = await suche.discover();
      expect(ergebnis.printers.single.host, '192.168.0.50');
      final txt = mdns.anfragen.where((a) => a.$1 == ResourceRecordType.text);
      expect(txt.single.$2, mdnsTxtFrist);
    });

    test('printer_identity aus: keine TXT-Abfrage', () async {
      final mdns = _StilleTxtMdns();
      final suche = PrinterDiscovery(
        mdnsClient: () => mdns,
        mitKennung: () async => false,
      );
      final ergebnis = await suche.discover();
      expect(ergebnis.printers.single.model, isNull);
      expect(
        mdns.anfragen.where((a) => a.$1 == ResourceRecordType.text),
        isEmpty,
      );
    });
  });
}
