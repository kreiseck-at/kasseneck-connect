import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-agent-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Agent makeAgent({int preferredPort = 0}) => Agent(
    store: store,
    log: log,
    preferredPort: preferredPort,
    openBrowser: false,
  );

  Future<String> get(int port, String path) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      final response = await request.close();
      return response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  test('start bindet auf 127.0.0.1 und antwortet auf /v1/status', () async {
    final agent = makeAgent();
    await agent.start();
    addTearDown(agent.stop);

    final body = jsonDecode(await get(agent.port, '/v1/status')) as Map;
    expect(body['ok'], isTrue);
    expect(body['port'], agent.port);
    expect(body['paired'], isFalse);
  });

  test('belegter Port führt zum nächsten freien Port', () async {
    final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => blocker.close(force: true));

    final agent = makeAgent(preferredPort: blocker.port);
    await agent.start();
    addTearDown(agent.stop);

    expect(agent.port, isNot(blocker.port));
    expect(agent.port, greaterThan(blocker.port));
    expect(agent.port, lessThanOrEqualTo(blocker.port + portFallbackRange - 1));
  });

  test('der gewählte Port landet in der Konfiguration', () async {
    final agent = makeAgent();
    await agent.start();
    addTearDown(agent.stop);

    expect((await store.load()).port, agent.port);
  });

  test(
    'ohne Token erzeugt der Start einen Kopplungscode und loggt ihn',
    () async {
      final agent = makeAgent();
      await agent.start();
      addTearDown(agent.stop);

      final code = (await store.load()).pairing.code;
      expect(code, matches(RegExp(r'^\d{6}$')));
      expect(log.file.readAsStringSync(), contains(code!));
    },
  );

  test('mit vorhandenem Token wird kein Code erzeugt', () async {
    await store.save(AgentConfig(tokenHashes: <String>[hashToken('egal')]));

    final agent = makeAgent();
    await agent.start();
    addTearDown(agent.stop);

    expect((await store.load()).pairing.code, isNull);
  });

  test('stop schließt den Server', () async {
    final agent = makeAgent();
    await agent.start();
    final port = agent.port;
    await agent.stop();

    await expectLater(get(port, '/v1/status'), throwsA(isA<SocketException>()));
  });

  test('die Kopplungsseite trägt Code und Port', () {
    expect(
      pairingPageUrl('123456', 27182),
      'https://kasse.kasseneck.at/connect#code=123456&port=27182',
    );
  });
}
