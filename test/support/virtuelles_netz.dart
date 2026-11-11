import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

/// Ein erfundenes Kassen-Netz 192.168.0.0/24 auf dem Rechner des Tests.
///
/// macOS kennt auf Loopback nur 127.0.0.1; ein Gerät „unter einer anderen
/// Adresse“ lässt sich so nicht echt aufstellen. Das Netz bildet deshalb
/// Adressen auf Ports von Fakes ab und liefert Verbindungsaufbau, TCP-Probe und
/// ARP-Ausgabe dazu. Alles, was nicht eingetragen ist, lehnt ab.
class VirtuellesNetz {
  /// Unsere Schnittstelle im Netz.
  static const LocalInterface eigene = LocalInterface(
    name: 'en0',
    address: '192.168.0.10',
  );

  /// Adresse → (Port im Netz → Port des Fakes auf 127.0.0.1).
  final Map<String, Map<int, int>> _geraete = <String, Map<int, int>>{};

  /// Adresse → MAC für die ARP-Tabelle.
  final Map<String, String> macs = <String, String>{};

  /// Adresse → MAC, die erst nach einem Kontakt (Verbindungsaufbau, Probe)
  /// in der ARP-Tabelle steht – wie im echten Netz nach einem Scan.
  final Map<String, String> macsNachKontakt = <String, String>{};

  final Set<String> _kontaktiert = <String>{};

  /// Verbindungsversuche je Adresse (auch abgelehnte).
  final Map<String, int> versuche = <String, int>{};

  /// Stellt einen Fake unter [host]:[port] auf; [macNachKontakt] steht erst
  /// nach dem ersten Kontakt in der ARP-Tabelle.
  void stelle(
    String host,
    int port,
    int fakePort, {
    String? mac,
    String? macNachKontakt,
  }) {
    _geraete.putIfAbsent(host, () => <int, int>{})[port] = fakePort;
    if (mac != null) macs[host] = mac;
    if (macNachKontakt != null) macsNachKontakt[host] = macNachKontakt;
  }

  /// Die ARP-Einträge jetzt: [macs] und die nach einem Kontakt.
  Map<String, String> get _arp => <String, String>{
    for (final host in _kontaktiert)
      if (macsNachKontakt[host] case final mac?) host: mac,
    ...macs,
  };

  /// Nimmt [host] aus dem Netz (die MAC bleibt in der ARP-Tabelle stehen,
  /// wie ein veralteter Eintrag).
  void entferne(String host) => _geraete.remove(host);

  Future<Socket> verbinden(String host, int port, {Duration? timeout}) {
    versuche[host] = (versuche[host] ?? 0) + 1;
    _kontaktiert.add(host);
    final ziel = _geraete[host]?[port];
    if (ziel == null) {
      return Future<Socket>.error(
        SocketException(
          'Connection refused',
          osError: const OSError('Connection refused', 61),
          address: InternetAddress.tryParse(host),
          port: port,
        ),
      );
    }
    return Socket.connect('127.0.0.1', ziel, timeout: timeout);
  }

  /// Dasselbe für `HttpClient.connectionFactory` (ePOS).
  Future<ConnectionTask<Socket>> httpVerbinden(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) {
    versuche[uri.host] = (versuche[uri.host] ?? 0) + 1;
    final ziel = _geraete[uri.host]?[uri.port];
    if (ziel == null) {
      return Future<ConnectionTask<Socket>>.error(
        SocketException(
          'Connection refused',
          osError: const OSError('Connection refused', 61),
          address: InternetAddress.tryParse(uri.host),
          port: uri.port,
        ),
      );
    }
    return Socket.startConnect('127.0.0.1', ziel);
  }

  Future<bool> tcp(String host, int port, Duration timeout) async {
    _kontaktiert.add(host);
    return _geraete[host]?[port] != null;
  }

  /// `arp -an` im Format von macOS.
  String arpTabelle() => _arp.entries
      .map((e) => '? (${e.key}) at ${e.value} on en0 ifscope [ethernet]\n')
      .join();

  /// `arp -n <ip>` im Format von macOS.
  String arpEinzeln(String ip) {
    final mac = _arp[ip];
    return mac == null
        ? '$ip ($ip) -- no entry\n'
        : '? ($ip) at $mac on en0 ifscope [ethernet]\n';
  }
}
