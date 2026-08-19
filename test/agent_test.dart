import 'dart:async';
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

  Future<String> get(int port, String path, {String? token}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (token != null) {
        request.headers
          ..set('origin', 'https://kasse.kasseneck.at')
          ..set('authorization', 'Bearer $token');
      }
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

  test('der Agent bringt die Drucker-Endpunkte mit', () async {
    const token = 'agent-token';
    await store.save(AgentConfig(tokenHashes: <String>[hashToken(token)]));

    final agent = makeAgent();
    await agent.start();
    addTearDown(agent.stop);

    final saved = await agent.printers.upsert(
      PrinterConfig(
        id: '',
        name: 'Kasse vorne',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
      ),
    );

    final printers =
        jsonDecode(await get(agent.port, '/v1/printers?probe=0', token: token))
            as Map<String, Object?>;
    expect((printers['printers']! as List).single, <String, Object?>{
      'id': saved.id,
      'name': 'Kasse vorne',
      'kind': 'tcp9100',
      'host': '192.168.0.50',
      'port': 9100,
      'state': 'unknown',
    });

    // Dieselbe Liste hängt in der Langform des Status.
    final status =
        jsonDecode(await get(agent.port, '/v1/status', token: token))
            as Map<String, Object?>;
    expect((status['printers']! as List).single, isA<Map<String, Object?>>());
  });

  test('die Kopplungsseite trägt Code und Port', () {
    expect(
      pairingPageUrl('123456', 27182),
      'https://kasse.kasseneck.at/connect#code=123456&port=27182',
    );
  });

  group('Browser beim ersten Start', () {
    late List<List<String>> calls;

    Agent agentWithRecorder({bool? openBrowser}) {
      calls = <List<String>>[];
      return Agent(
        store: store,
        log: log,
        preferredPort: 0,
        openBrowser: openBrowser,
        pairing: Pairing(
          store: store,
          log: log,
          runProcess: (executable, arguments) async {
            calls.add(<String>[executable, ...arguments]);
            return ProcessResult(0, 0, '', '');
          },
        ),
      );
    }

    test('ohne Token wird die Kopplungsseite geöffnet', () async {
      final agent = agentWithRecorder();
      await agent.start();
      addTearDown(agent.stop);

      final code = (await store.load()).pairing.code;
      expect(calls, hasLength(1));
      expect(calls.single.last, contains('code=$code'));
      expect(calls.single.last, contains('port=${agent.port}'));
    });

    test('openBrowser: false öffnet nichts', () async {
      final agent = agentWithRecorder(openBrowser: false);
      await agent.start();
      addTearDown(agent.stop);

      expect((await store.load()).pairing.code, isNotNull);
      expect(calls, isEmpty);
    });
  });

  // Der harte Zweig (`close(force: true)` nach dem Zeitablauf) lässt sich von
  // außen nicht provozieren: `HttpServer.close()` kehrt auch bei einer offenen,
  // unbeantworteten Anfrage sofort zurück. Getestet ist deshalb, dass `stop()`
  // in diesem Fall nicht hängen bleibt — die Zeitgrenze bleibt Sicherheitsnetz.
  test('stop bleibt bei einer hängenden Anfrage nicht stehen', () async {
    final hanging = Completer<void>();
    addTearDown(() {
      if (!hanging.isCompleted) hanging.complete();
    });

    final agent = Agent(
      store: store,
      log: log,
      preferredPort: 0,
      openBrowser: false,
      extraRoutes: <RouteRegistrar>[
        (router, context) => router.get('/v1/haengt', (_) async {
          await hanging.future;
          return okJson(<String, Object?>{});
        }),
      ],
    );
    await agent.start();

    // Anfrage abschicken und laufen lassen — die Antwort kommt nie.
    unawaited(get(agent.port, '/v1/haengt').catchError((Object _) => ''));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final started = DateTime.now();
    await agent.stop();
    final needed = DateTime.now().difference(started);

    expect(needed, lessThan(gracefulStopTimeout + const Duration(seconds: 2)));
    expect(log.file.readAsStringSync(), contains('Agent angehalten.'));
    await expectLater(
      get(agent.port, '/v1/status'),
      throwsA(isA<SocketException>()),
    );
  });
}
