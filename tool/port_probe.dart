import 'dart:io';

Future<void> main() async {
  var gleich = 0;
  final abstaende = <int>[];
  for (var i = 0; i < 50; i++) {
    final a = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = a.port;
    await a.close();
    final b = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    if (b.port == p) gleich++;
    abstaende.add(b.port - p);
    await b.close();
  }
  print('PROBE gleicher Port direkt nach close: $gleich/50');
  print('PROBE Abstände: ${abstaende.take(25).toList()}');
  final offen = <ServerSocket>[];
  for (var i = 0; i < 12; i++) {
    offen.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  }
  print('PROBE Folge ohne close: ${offen.map((s) => s.port).toList()}');
  for (final s in offen) {
    await s.close();
  }
}
