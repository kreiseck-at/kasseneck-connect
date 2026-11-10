import 'dart:io';

/// Adresse, unter der im Test „niemand annimmt“: ein Verbindungsaufbau dorthin
/// scheitert sofort wie bei einem ausgeschalteten Gerät.
///
/// Statt eines eben geschlossenen Ports: den kann ein parallel laufender Test
/// sofort wieder belegen, dann spräche der Test mit einem fremden Server.
const String toteAdresse = '192.168.0.99';

/// Die Ausnahme eines abgelehnten Verbindungsaufbaus.
SocketException abgelehnt(String host, int port) => SocketException(
  'Connection refused',
  osError: const OSError('Connection refused', 61),
  address: InternetAddress.tryParse(host),
  port: port,
);

/// Verbindungsaufbau wie `Socket.connect`, aber [toteAdresse] lehnt ab.
Future<Socket> verbindenOhneTote(String host, int port, {Duration? timeout}) =>
    host == toteAdresse
    ? Future<Socket>.error(abgelehnt(host, port))
    : Socket.connect(host, port, timeout: timeout);

/// Dasselbe für `HttpClient.connectionFactory` (Terminal-Brücke).
Future<ConnectionTask<Socket>> httpOhneTote(
  Uri uri,
  String? proxyHost,
  int? proxyPort,
) => uri.host == toteAdresse
    ? Future<ConnectionTask<Socket>>.error(abgelehnt(uri.host, uri.port))
    : Socket.startConnect(uri.host, uri.port);
