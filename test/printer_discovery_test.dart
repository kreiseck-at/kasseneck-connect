import 'dart:async';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

void main() {
  DiscoveredPrinter found(
    String host, {
    int port = 9100,
    String? name,
    PrinterKind kind = PrinterKind.tcp9100,
  }) => DiscoveredPrinter(host: host, port: port, name: name, kind: kind);

  group('Suche', () {
    test('ohne Scan wird nur mDNS befragt', () async {
      var scanned = false;
      final discovery = PrinterDiscovery(
        mdns: (_) async => <DiscoveredPrinter>[
          found('192.168.0.50', name: 'TM-T20'),
        ],
        scan: () async {
          scanned = true;
          return <DiscoveredPrinter>[];
        },
      );

      final result = await discovery.discover();

      expect(scanned, isFalse);
      expect(result.single.toJson(), <String, Object?>{
        'host': '192.168.0.50',
        'port': 9100,
        'name': 'TM-T20',
        'kind': 'tcp9100',
      });
    });

    test('mit Scan werden beide Quellen zusammengeführt', () async {
      final discovery = PrinterDiscovery(
        mdns: (_) async => <DiscoveredPrinter>[
          found('192.168.0.50', name: 'TM-T20'),
        ],
        scan: () async => <DiscoveredPrinter>[
          found('192.168.0.50'),
          found('192.168.0.77'),
        ],
      );

      final result = await discovery.discover(scan: true);

      expect(result.map((e) => e.host), <String>[
        '192.168.0.50',
        '192.168.0.77',
      ]);
      expect(result.first.name, 'TM-T20', reason: 'Name aus mDNS bleibt');
    });

    test('derselbe Host mit anderem Port bleibt ein eigener Treffer', () async {
      final discovery = PrinterDiscovery(
        mdns: (_) async => <DiscoveredPrinter>[
          found('192.168.0.50', port: 80, kind: PrinterKind.epos),
          found('192.168.0.50'),
        ],
      );

      expect(await discovery.discover(), hasLength(2));
    });

    test(
      'eine kaputte Suche liefert eine leere Liste statt eines Fehlers',
      () async {
        final discovery = PrinterDiscovery(
          mdns: (_) async => throw StateError('kein Netz'),
          scan: () async => throw StateError('kein Interface'),
        );

        expect(await discovery.discover(scan: true), isEmpty);
      },
    );
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
  });

  test('Dienstnamen ergeben die Anbindungsart', () {
    expect(kindForService('_epos._tcp.local'), PrinterKind.epos);
    expect(kindForService('_printer._tcp.local'), PrinterKind.tcp9100);
    expect(kindForService('_pdl-datastream._tcp.local'), PrinterKind.tcp9100);
    expect(printerServices, hasLength(3));
  });
}
