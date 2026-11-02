import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'support/port_zu.dart';

void main() {
  Future<String> get(int port) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/v1/status'),
      );
      final response = await request.close();
      return await response.drain<String>('');
    } finally {
      client.close(force: true);
    }
  }

  test('nichts lauscht: sofort erfüllt', () async {
    final frei = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = frei.port;
    await frei.close();

    await erwartePortZu(() => get(port));
  });

  test(
    'erst abgebrochen, dann abgelehnt: wartet, bis niemand mehr annimmt',
    () async {
      // Wie die Kopie eines Lauschsockets in einem gerade geforkten Kind:
      // die Verbindung wird angenommen, aber nie beantwortet und dann zu.
      final kopie = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = kopie.port;
      var angenommen = 0;
      kopie.listen((socket) {
        angenommen++;
        socket.destroy();
        unawaited(kopie.close());
      });

      await erwartePortZu(() => get(port));
      expect(angenommen, 1);
    },
  );

  test('antwortet der Server noch, scheitert es sofort', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) => request.response.close());

    final start = DateTime.now();
    await expectLater(
      erwartePortZu(() => get(server.port)),
      throwsA(isA<TestFailure>()),
    );
    expect(
      DateTime.now().difference(start),
      lessThan(const Duration(seconds: 1)),
    );
  });

  test('wird der Port nie frei, scheitert es nach der Frist', () async {
    final stur = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(stur.close);
    stur.listen((socket) => socket.destroy());

    await expectLater(
      erwartePortZu(
        () => get(stur.port),
        frist: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TestFailure>()),
    );
  });
}
