import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

const String _openssl = '/usr/bin/openssl';
const String _security = '/usr/bin/security';
const String _kasse = 'https://kasse.kasseneck.at';

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

  Future<String> ssAusgabe(List<String> args) async {
    if (!Platform.isLinux) return '';
    final r = await Process.run('ss', args);
    return '${r.stdout}${r.stderr}'.trim().replaceAll('\n', ' | ');
  }

  Future<String> lauscher(int port) =>
      ssAusgabe(<String>['-ltnpeH', 'sport', '=', ':$port']);

  Future<String> alle(int port) => ssAusgabe(<String>[
    '-tanpeH',
    '(',
    'sport',
    '=',
    ':$port',
    'or',
    'dport',
    '=',
    ':$port',
    ')',
  ]);

  Future<void> pruefeZu(String name, int port, String vorher) async {
    Object? fehler;
    try {
      await get(port, '/v1/status');
      fehler = 'antwortet nach stop';
    } on SocketException {
      fehler = null;
    } on Object catch (e) {
      fehler = e;
    }
    final nachher = await lauscher(port);
    if (fehler != null || nachher.isNotEmpty) {
      print('DIAG [$name] port=$port fehler=$fehler');
      print('DIAG [$name] vorher=$vorher');
      print('DIAG [$name] nachher=$nachher');
      print('DIAG [$name] alle=${await alle(port)}');
    }
    if (fehler != null) fail('$fehler');
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
    final vorher = await lauscher(port);
    await agent.stop();

    await pruefeZu('stop schliesst', port, vorher);
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

    // Der Port muss **vor** dem Anhalten festgehalten werden: danach meldet
    // `agent.port` 0, und die Abfrage unten prüfte einen Port, auf dem nie ein
    // Agent lauschte — sie schlüge auch dann fehl, wenn er noch stünde.
    final port = agent.port;
    expect(port, greaterThan(0));

    final vorher = await lauscher(port);
    final started = DateTime.now();
    await agent.stop();
    final needed = DateTime.now().difference(started);

    await pruefeZu('haengend', port, vorher);
    expect(needed, lessThan(gracefulStopTimeout + const Duration(seconds: 2)));
    expect(log.file.readAsStringSync(), contains('Agent angehalten.'));
  });
  group('HTTPS', () {
    // Echte Zertifikate brauchen echtes openssl; ohne wird übersprungen.
    final ohneOpenssl = File(_openssl).existsSync() ? null : 'kein $_openssl';

    late FakeProcessRunner runner;

    setUp(() {
      // openssl und chmod laufen echt (Zertifikate im Temp-Ordner),
      // `security` bleibt Attrappe: kein Test fragt den echten Schlüsselbund.
      runner = FakeProcessRunner()
        ..echt.addAll(<String>{_openssl, 'chmod'})
        ..exitCodes['verify-cert'] = 1;
    });

    String tlsDatei(String name) => p.join(temp.path, 'tls', name);

    List<int> serverZertifikat() =>
        _der(File(tlsDatei('server-cert.pem')).readAsStringSync());

    Agent httpsAgent({
      FakeProcessRunner? mit,
      LocalCertificates? certificates,
      int preferredHttpsPort = 0,
      Duration tlsCheckInterval = const Duration(days: 1),
    }) => Agent(
      store: store,
      log: log,
      preferredPort: 0,
      openBrowser: false,
      https: true,
      preferredHttpsPort: preferredHttpsPort,
      runProcess: (mit ?? runner).runner,
      certificates: certificates,
      tlsCheckInterval: tlsCheckInterval,
    );

    Future<_Antwort> https(
      int port,
      String path, {
      String method = 'GET',
      String? origin,
      String? token,
    }) async {
      final client = _httpsClient(Directory(p.join(temp.path, 'tls')));
      try {
        final request = await client.openUrl(
          method,
          Uri.parse('https://127.0.0.1:$port$path'),
        );
        if (origin != null) request.headers.set('origin', origin);
        if (token != null) {
          request.headers.set('authorization', 'Bearer $token');
        }
        final response = await request.close();
        final text = await response.transform(utf8.decoder).join();
        return _Antwort(
          response.statusCode,
          response.headers,
          text.isEmpty
              ? const <String, Object?>{}
              : jsonDecode(text) as Map<String, Object?>,
          response.certificate!.der.toList(),
        );
      } finally {
        client.close(force: true);
      }
    }

    /// Koppelt über HTTP und liefert den Token.
    Future<String> koppeln(Agent agent) async {
      final code = await agent.context.pairing.newCode();
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${agent.port}/v1/pair'),
        );
        request.headers
          ..set('origin', _kasse)
          ..contentType = ContentType.json;
        request.write(jsonEncode(<String, Object?>{'code': code}));
        final response = await request.close();
        final json =
            jsonDecode(await response.transform(utf8.decoder).join()) as Map;
        return json['token'] as String;
      } finally {
        client.close(force: true);
      }
    }

    Iterable<String> securityAufrufe(FakeProcessRunner r) => r.calls
        .where((c) => c.executable == _security)
        .map((c) => c.arguments.first);

    /// Die Zertifikate, die der Zugang an [port] im Handshake vorlegt (DER,
    /// in dieser Reihenfolge). Gelesen mit `openssl s_client -showcerts`: ein
    /// Dart-Client zeigt nur das Blatt.
    Future<List<List<int>>> vorgelegteKette(int port) async {
      final prozess = await Process.start(_openssl, <String>[
        's_client',
        '-connect',
        '127.0.0.1:$port',
        '-showcerts',
      ]);
      // Ohne Eingabe beendet s_client die Verbindung nach dem Handshake.
      await prozess.stdin.close();
      final ausgabe = prozess.stdout.transform(utf8.decoder).join();
      final fehler = prozess.stderr.transform(utf8.decoder).join();
      final code = await prozess.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          prozess.kill();
          return -1;
        },
      );
      expect(code, 0, reason: await fehler);
      final kette = RegExp(
        r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----',
      ).allMatches(await ausgabe).map((m) => _der(m[0]!)).toList();
      expect(kette, hasLength(2), reason: 'Serverzertifikat und Stelle');
      return kette;
    }

    List<int> stelleDer() =>
        _der(File(tlsDatei('ca-cert.pem')).readAsStringSync());

    test('HTTPS legt das Serverzertifikat und dahinter die Stelle vor, auch '
        'nach einer neuen Stelle', () async {
      final agent = httpsAgent();
      await agent.start();
      addTearDown(agent.stop);
      final port = agent.httpsPort!;

      // Ein Browser am Mac findet die Stelle so auch dann, wenn sie nicht im
      // Schlüsselbund liegt — es reicht der Vertrauenseintrag.
      final vorher = <List<int>>[serverZertifikat(), stelleDer()];
      expect(await vorgelegteKette(port), vorher);

      // Fehlt die Stelle, entsteht ein neuer Satz: der Zugang bindet neu, und
      // die Kette trägt die neue Stelle.
      File(tlsDatei('ca-cert.pem')).deleteSync();
      await agent.checkTls();
      final nachher = <List<int>>[serverZertifikat(), stelleDer()];
      expect(nachher[1], isNot(vorher[1]));
      expect(agent.httpsPort, port);
      expect(await vorgelegteKette(port), nachher);
    }, skip: ohneOpenssl);

    test(
      'eine andere Stelle bei gleichem Serverzertifikat bindet neu',
      () async {
        final zertifikate = _UmlenkbareZertifikate(
          directory: temp,
          run: runner.runner,
          log: log,
        );
        final agent = httpsAgent(certificates: zertifikate);
        await agent.start();
        addTearDown(agent.stop);
        final port = agent.httpsPort!;
        final blatt = serverZertifikat();

        final anders = Directory.systemTemp.createTempSync('connect-agent-');
        addTearDown(() => anders.deleteSync(recursive: true));
        final fremd = await LocalCertificates(
          directory: anders,
          run: runner.runner,
          log: log,
        ).ensure();
        zertifikate.umlenken = TlsFiles(
          caCertPath: fremd.caCertPath,
          serverCertPath: tlsDatei('server-cert.pem'),
          serverKeyPath: tlsDatei('server-key.pem'),
          serverNotAfter: fremd.serverNotAfter,
          caCreated: false,
        );

        await agent.checkTls();

        expect(agent.httpsPort, port);
        expect(await vorgelegteKette(port), <List<int>>[
          blatt,
          _der(File(fremd.caCertPath).readAsStringSync()),
        ]);
      },
      skip: ohneOpenssl,
    );

    test('Agent lauscht über HTTPS und HTTP mit demselben Token', () async {
      final agent = httpsAgent();
      await agent.start();
      addTearDown(agent.stop);

      expect(agent.httpsPort, isNotNull);
      expect(agent.httpsPort, isNot(agent.port));
      final token = await koppeln(agent);

      final ueberHttps = await https(
        agent.httpsPort!,
        '/v1/status',
        origin: _kasse,
        token: token,
      );
      expect(ueberHttps.status, 200);
      expect(ueberHttps.zertifikat, serverZertifikat());
      expect(ueberHttps.json['port'], agent.port);
      expect(ueberHttps.json['httpsPort'], agent.httpsPort);
      expect(ueberHttps.json['features'], contains('https'));
      // Langform: der über HTTP ausgegebene Token gilt auch hier.
      expect(ueberHttps.json.containsKey('printers'), isTrue);
      final tls = ueberHttps.json['tls']! as Map<String, Object?>;
      expect(tls['trusted'], isFalse);
      expect(
        DateTime.parse(
          tls['notAfter']! as String,
        ).isAfter(DateTime.now().add(const Duration(days: 390))),
        isTrue,
      );

      final ueberHttp =
          jsonDecode(await get(agent.port, '/v1/status', token: token))
              as Map<String, Object?>;
      expect(ueberHttp['httpsPort'], agent.httpsPort);
      expect(ueberHttp['features'], contains('https'));
      expect(ueberHttp.containsKey('printers'), isTrue);

      // Der Port landet in der Konfiguration, wie der HTTP-Port.
      expect((await store.load()).httpsPort, agent.httpsPort);

      // Vertrauen fragt der Agent nur ab und warnt im Log; eintragen tut er
      // es nie selbst — kein Dialog aus dem Hintergrund bei der Anmeldung.
      expect(securityAufrufe(runner), contains('verify-cert'));
      expect(securityAufrufe(runner), everyElement('verify-cert'));
      expect(log.file.readAsStringSync(), contains('zertifikat-vertrauen'));
    }, skip: ohneOpenssl);

    test('Herkunft und Token gelten auch über HTTPS', () async {
      final agent = httpsAgent();
      await agent.start();
      addTearDown(agent.stop);
      final token = await koppeln(agent);
      final port = agent.httpsPort!;

      final fremd = await https(
        port,
        '/v1/status',
        origin: 'https://boese.example.com',
      );
      expect(fremd.status, 403);
      expect((fremd.json['error']! as Map)['code'], errorOriginForbidden);

      final ohneToken = await https(
        port,
        '/v1/printers?probe=0',
        origin: _kasse,
      );
      expect(ohneToken.status, 401);
      expect((ohneToken.json['error']! as Map)['code'], errorUnauthorized);

      final falsch = await https(
        port,
        '/v1/printers?probe=0',
        origin: _kasse,
        token: 'falsch',
      );
      expect(falsch.status, 401);

      final richtig = await https(
        port,
        '/v1/printers?probe=0',
        origin: _kasse,
        token: token,
      );
      expect(richtig.status, 200);
      expect(richtig.json['ok'], isTrue);

      final preflight = await https(
        port,
        '/v1/print',
        method: 'OPTIONS',
        origin: _kasse,
      );
      expect(preflight.status, 204);
      expect(
        preflight.headers.value('access-control-allow-private-network'),
        'true',
      );
      expect(preflight.headers.value('access-control-allow-origin'), _kasse);
    }, skip: ohneOpenssl);

    test(
      'HTTPS scheitert (kein openssl): HTTP läuft, features ohne https',
      () async {
        final ohne = FakeProcessRunner()..missing.add(_openssl);
        final agent = httpsAgent(mit: ohne);
        await agent.start();
        addTearDown(agent.stop);

        expect(agent.httpsPort, isNull);
        const token = 'agent-token';
        await store.mutate(
          (c) => c.copyWith(tokenHashes: <String>[hashToken(token)]),
        );
        final kurz =
            jsonDecode(await get(agent.port, '/v1/status'))
                as Map<String, Object?>;
        expect(kurz['ok'], isTrue);
        expect(kurz.containsKey('httpsPort'), isTrue);
        expect(kurz['httpsPort'], isNull);
        expect(kurz['features'], isNot(contains('https')));
        final lang =
            jsonDecode(await get(agent.port, '/v1/status', token: token))
                as Map<String, Object?>;
        expect(lang['features'], isNot(contains('https')));
        expect(lang.containsKey('tls'), isFalse);

        expect(log.file.readAsStringSync(), contains('HTTPS'));
        expect(securityAufrufe(ohne), isEmpty);
        // Der gemerkte HTTPS-Port bleibt stehen.
        expect((await store.load()).httpsPort, defaultHttpsPort);
      },
    );

    test('belegter HTTPS-Port führt zum nächsten freien Port', () async {
      final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => blocker.close(force: true));

      final agent = httpsAgent(preferredHttpsPort: blocker.port);
      await agent.start();
      addTearDown(agent.stop);

      expect(agent.httpsPort, greaterThan(blocker.port));
      expect(
        agent.httpsPort,
        lessThanOrEqualTo(blocker.port + portFallbackRange - 1),
      );
      expect((await https(agent.httpsPort!, '/v1/status')).status, 200);
    }, skip: ohneOpenssl);

    test(
      'erneuertes Serverzertifikat wird ohne Neustart des Agenten übernommen',
      () async {
        var uhr = DateTime.now();
        final zertifikate = LocalCertificates(
          directory: temp,
          run: runner.runner,
          log: log,
          clock: () => uhr,
        );
        final agent = httpsAgent(certificates: zertifikate);
        await agent.start();
        addTearDown(agent.stop);

        final httpPort = agent.port;
        final httpsPort = agent.httpsPort!;
        final stelle = File(tlsDatei('ca-cert.pem')).readAsStringSync();
        final vorher = serverZertifikat();
        expect((await https(httpsPort, '/v1/status')).zertifikat, vorher);

        // 368 Tage später läuft das Serverzertifikat in weniger als 30
        // Tagen ab — die tägliche Prüfung erneuert es.
        uhr = uhr.add(const Duration(days: 368));
        await agent.checkTls();

        final nachher = serverZertifikat();
        expect(nachher, isNot(vorher));
        expect(
          File(tlsDatei('ca-cert.pem')).readAsStringSync(),
          stelle,
          reason: 'nur das Serverzertifikat ist neu',
        );
        expect((await https(httpsPort, '/v1/status')).zertifikat, nachher);

        // Gleicher HTTPS-Port, HTTP unberührt, kein Neustart.
        expect(agent.httpsPort, httpsPort);
        expect(agent.port, httpPort);
        final status =
            jsonDecode(await get(httpPort, '/v1/status'))
                as Map<String, Object?>;
        expect(status['ok'], isTrue);
        expect(status['httpsPort'], httpsPort);
        expect(
          log.file.readAsStringSync(),
          contains('HTTPS-Zugang mit neuen Zertifikaten neu gebunden'),
        );
      },
      skip: ohneOpenssl,
    );

    test('passen Zertifikat und Schlüssel nach einer Erneuerung nicht '
        'zusammen, bleibt der alte Zugang stehen', () async {
      final zertifikate = _UmlenkbareZertifikate(
        directory: temp,
        run: runner.runner,
        log: log,
      );
      final agent = httpsAgent(certificates: zertifikate);
      await agent.start();
      addTearDown(agent.stop);
      final port = agent.httpsPort!;
      final vorher = serverZertifikat();

      // Ein zweiter Satz in einem anderen Ordner: sein Zertifikat passt nicht
      // zum Schlüssel des ersten.
      final anders = Directory.systemTemp.createTempSync('connect-agent-');
      addTearDown(() => anders.deleteSync(recursive: true));
      final fremd = await LocalCertificates(
        directory: anders,
        run: runner.runner,
        log: log,
      ).ensure();
      zertifikate.umlenken = TlsFiles(
        caCertPath: fremd.caCertPath,
        serverCertPath: fremd.serverCertPath,
        serverKeyPath: tlsDatei('server-key.pem'),
        serverNotAfter: fremd.serverNotAfter,
        caCreated: false,
      );

      await agent.checkTls();

      expect(agent.httpsPort, port);
      expect((await https(port, '/v1/status')).zertifikat, vorher);
      expect(
        log.file.readAsStringSync(),
        contains('Prüfung der Zertifikate gescheitert'),
      );
    }, skip: ohneOpenssl);

    test('die tägliche Prüfung läuft über den Zeitgeber', () async {
      final agent = httpsAgent(
        tlsCheckInterval: const Duration(milliseconds: 200),
      );
      await agent.start();
      addTearDown(agent.stop);
      final port = agent.httpsPort!;
      final vorher = serverZertifikat();

      // Fehlt das Serverzertifikat, stellt die nächste Prüfung es neu aus und
      // bindet den Zugang neu — von selbst, ohne Aufruf von außen.
      File(tlsDatei('server-cert.pem')).deleteSync();

      final ende = DateTime.now().add(const Duration(seconds: 20));
      List<int>? vorgelegt;
      // Ein Fehler beim Neubinden ist erlaubt — scheitert aber jeder Versuch,
      // soll die Meldung sagen, woran, statt nur „null“.
      IOException? letzterFehler;
      while (DateTime.now().isBefore(ende)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final datei = File(tlsDatei('server-cert.pem'));
        if (!datei.existsSync()) continue;
        try {
          vorgelegt = (await https(port, '/v1/status')).zertifikat;
        } on IOException catch (fehler) {
          letzterFehler = fehler;
          continue; // gerade beim Neubinden
        }
        if (!_gleich(vorgelegt, vorher)) break;
      }
      expect(vorgelegt, isNotNull, reason: 'zuletzt: $letzterFehler');
      expect(vorgelegt, isNot(vorher), reason: 'zuletzt: $letzterFehler');
      expect(vorgelegt, serverZertifikat());
    }, skip: ohneOpenssl);

    test('Gegenprobe: der Testclient lehnt die Kette einer fremden Stelle '
        'ab', () async {
      final zertifikate = _UmlenkbareZertifikate(
        directory: temp,
        run: runner.runner,
        log: log,
      );
      final agent = httpsAgent(certificates: zertifikate);
      await agent.start();
      addTearDown(agent.stop);
      final port = agent.httpsPort!;
      expect((await https(port, '/v1/status')).status, 200);

      // Ein ganzer zweiter Satz mit eigener Stelle: der Zugang bindet neu und
      // legt dessen Kette vor. Der Client traut weiter nur der ersten Stelle.
      final anders = Directory.systemTemp.createTempSync('connect-agent-');
      addTearDown(() => anders.deleteSync(recursive: true));
      zertifikate.umlenken = await LocalCertificates(
        directory: anders,
        run: runner.runner,
        log: log,
      ).ensure();
      await agent.checkTls();
      expect(agent.httpsPort, port);

      await expectLater(
        https(port, '/v1/status'),
        throwsA(isA<HandshakeException>()),
      );
    }, skip: ohneOpenssl);

    test('stop schließt auch den HTTPS-Zugang', () async {
      final agent = httpsAgent();
      await agent.start();
      final port = agent.httpsPort!;
      await agent.stop();

      expect(agent.httpsPort, isNull);
      await expectLater(
        https(port, '/v1/status'),
        throwsA(isA<SocketException>()),
      );
    }, skip: ohneOpenssl);

    test(
      'ohne https: kein zweiter Zugang, kein openssl, kein security',
      () async {
        final agent = Agent(
          store: store,
          log: log,
          preferredPort: 0,
          openBrowser: false,
          runProcess: runner.runner,
        );
        await agent.start();
        addTearDown(agent.stop);

        expect(agent.httpsPort, isNull);
        expect(runner.calls, isEmpty);
        expect(Directory(p.join(temp.path, 'tls')).existsSync(), isFalse);
      },
    );
  });
}

/// Zertifikate, deren nächstes [ensure] auf einen anderen Satz zeigen kann —
/// so lässt sich ein Stand nachstellen, den [LocalCertificates] selbst nie
/// hinterlässt.
class _UmlenkbareZertifikate extends LocalCertificates {
  _UmlenkbareZertifikate({
    required super.directory,
    required super.run,
    required super.log,
  });

  TlsFiles? umlenken;

  @override
  Future<TlsFiles> ensure() async => umlenken ?? await super.ensure();
}

class _Antwort {
  _Antwort(this.status, this.headers, this.json, this.zertifikat);

  final int status;
  final HttpHeaders headers;
  final Map<String, Object?> json;

  /// Das vom Server vorgelegte Zertifikat (DER).
  final List<int> zertifikat;
}

/// HTTPS-Client, dessen einziger Anker die Test-Stelle im Ordner [tls] ist —
/// der Schlüsselbund des Rechners bleibt unberührt. Geprüft wird die Kette,
/// die der Zugang vorlegt (Blatt, dahinter die Stelle), bis zu diesem Anker.
///
/// Unter macOS prüft Dart mit der Vertrauensprüfung des Systems (wie Safari),
/// samt Namensbeschränkung. BoringSSL (Dart unter Linux) baut und prüft die
/// Kette ebenso bis zur Stelle, kennt aber keine IP-Namensbeschränkung und
/// meldet deshalb am Blatt „unsupported name constraint type“. Nur dort lässt
/// der Client nach, und nur für das Zertifikat, das Byte für Byte in
/// `server-cert.pem` steht. Jede andere Abweichung bleibt ein Fehler — eine
/// Stelle in der Kette, die nicht der Anker ist, kommt als „self signed
/// certificate in certificate chain“ mit der Stelle im Rückruf, nicht dem
/// Blatt. Die Namensbeschränkung selbst prüfen die Tests mit echtem openssl.
HttpClient _httpsClient(Directory tls) {
  final client = HttpClient(
    context: SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(p.join(tls.path, 'ca-cert.pem')),
  );
  if (Platform.isMacOS) return client;
  final blatt = _der(
    File(p.join(tls.path, 'server-cert.pem')).readAsStringSync(),
  );
  return client
    ..badCertificateCallback = (zertifikat, host, port) =>
        host == '127.0.0.1' && _gleich(zertifikat.der, blatt);
}

List<int> _der(String pem) => base64.decode(
  pem
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), ''),
);

bool _gleich(List<int>? a, List<int> b) {
  if (a == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
