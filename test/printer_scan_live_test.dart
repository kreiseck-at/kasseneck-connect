import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

/// Netzscan gegen echte Sockets — ohne eingeschobene Verbindungsprüfung.
///
/// Der Scan läuft über das Loopback-Netz: die Schnittstellenliste wird
/// eingeschoben (`127.0.0.99`), damit `subnetHosts` das echte `127.0.0.1`
/// mitzählt — die eigene Adresse lässt der Scan ja aus. Damit hängt der Test
/// weder am WLAN des Entwicklerrechners noch an einem bestimmten Drucker,
/// prüft aber die Maschinerie, die im Betrieb wirklich läuft: Verbindung,
/// Zeitlimit und Nebenläufigkeit.
void main() {
  test(
    'der Scan findet einen wirklich lauschenden Port',
    () async {
      final fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => fake.close());
      fake.listen((socket) => socket.destroy());

      final discovery = PrinterDiscovery(
        mdns: (_) async => const <DiscoveredPrinter>[],
        interfaces: () async => const <LocalInterface>[
          LocalInterface(name: 'lo-test', address: '127.0.0.99'),
        ],
        scanPort: fake.port,
        // Bewusst zurückhaltend: der Test läuft neben den anderen Testdateien,
        // und 64 gleichzeitige Verbindungen aufs Loopback bringen deren Server
        // ins Stocken.
        scanConcurrency: 16,
      );

      final result = await discovery.discover(scan: true);

      expect(result.printers.map((e) => e.host), contains('127.0.0.1'));
      expect(result.printers.first.port, fake.port);
      expect(result.scanned.single.subnet, '127.0.0.0/24');
      expect(result.scanned.single.hosts, 253);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'ein geschlossener Port taucht nicht auf',
    () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();

      final discovery = PrinterDiscovery(
        mdns: (_) async => const <DiscoveredPrinter>[],
        interfaces: () async => const <LocalInterface>[
          LocalInterface(name: 'lo-test', address: '127.0.0.99'),
        ],
        scanPort: port,
        scanConcurrency: 16,
      );

      expect((await discovery.discover(scan: true)).printers, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
