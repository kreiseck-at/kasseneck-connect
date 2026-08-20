import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Antwort des Testklienten in bequemer Form.
class TestResponse {
  TestResponse(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final String body;

  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;

  bool get ok => json['ok'] == true;

  String? get errorCode {
    final error = json['error'];
    return error is Map ? error['code'] as String? : null;
  }
}

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late AgentContext ctx;
  late HttpServer server;
  late DateTime now;
  late FakeProcessRunner browser;

  const kasse = 'https://kasse.kasseneck.at';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-api-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    now = DateTime(2026, 8, 19, 10);
    browser = FakeProcessRunner();
    ctx = AgentContext(
      store: store,
      log: log,
      startedAt: now,
      clock: () => now,
      // Leere Umgebung: der Test entscheidet über
      // KASSENECK_CONNECT_NO_BROWSER, nicht der Rechner, auf dem er läuft.
      environment: const <String, String>{},
      pairing: Pairing(
        store: store,
        log: log,
        clock: () => now,
        random: Random(11),
        runProcess: browser.runner,
      ),
    );
    server = await shelf_io.serve(
      buildHandler(ctx),
      InternetAddress.loopbackIPv4,
      0,
    );
    ctx.port = server.port;
  });

  tearDown(() async {
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  Future<TestResponse> send(
    String method,
    String path, {
    String? origin,
    String? token,
    Object? body,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (origin != null) request.headers.set('origin', origin);
      if (token != null) request.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return TestResponse(response.statusCode, response.headers, text);
    } finally {
      client.close(force: true);
    }
  }

  /// Koppelt und liefert den Klartext-Token.
  Future<String> pair() async {
    final code = await ctx.pairing.newCode();
    final response = await send(
      'POST',
      '/v1/pair',
      origin: kasse,
      body: <String, Object?>{'code': code},
    );
    return response.json['token'] as String;
  }

  group('CORS', () {
    test('erlaubt jede Herkunft der Allowlist', () async {
      for (final origin in <String>[
        'https://kasse.kasseneck.at',
        'https://kasseneck-kasse.web.app',
        'https://kasseneck-kasse.firebaseapp.com',
      ]) {
        final response = await send('GET', '/v1/status', origin: origin);
        expect(response.status, 200, reason: origin);
        expect(
          response.headers.value('access-control-allow-origin'),
          origin,
          reason: origin,
        );
        expect(response.headers.value('vary'), contains('Origin'));
      }
    });

    test('fremde Herkunft bekommt 403 origin_forbidden', () async {
      final response = await send(
        'GET',
        '/v1/status',
        origin: 'https://boese.example.com',
      );
      expect(response.status, 403);
      expect(response.errorCode, errorOriginForbidden);
      expect(response.headers.value('access-control-allow-origin'), isNull);
      // Auch die Ablehnung hängt von der Herkunft ab — sonst legt ein Cache sie
      // für eine erlaubte Herkunft ab.
      expect(response.headers.value('vary'), contains('Origin'));
    });

    test('Herkunft mit gleichem Präfix zählt nicht als erlaubt', () async {
      final response = await send(
        'GET',
        '/v1/status',
        origin: 'https://kasse.kasseneck.at.boese.example',
      );
      expect(response.status, 403);
    });

    test('Preflight antwortet 204 mit PNA-Kopfzeile', () async {
      final response = await send('OPTIONS', '/v1/print', origin: kasse);
      expect(response.status, 204);
      expect(
        response.headers.value('access-control-allow-private-network'),
        'true',
      );
      expect(response.headers.value('access-control-allow-origin'), kasse);
      expect(
        response.headers.value('access-control-allow-headers'),
        contains('Authorization'),
      );
      expect(
        response.headers.value('access-control-allow-methods'),
        contains('DELETE'),
      );
    });

    test('Preflight fremder Herkunft wird abgelehnt', () async {
      final response = await send(
        'OPTIONS',
        '/v1/print',
        origin: 'https://boese.example.com',
      );
      expect(response.status, 403);
      expect(
        response.headers.value('access-control-allow-private-network'),
        isNull,
      );
    });

    test('ohne Origin sind nur Status und Pair erlaubt', () async {
      expect((await send('GET', '/v1/status')).status, 200);
      expect(
        (await send(
          'POST',
          '/v1/pair',
          body: <String, Object?>{'code': '000000'},
        )).status,
        200,
      );

      final blocked = await send('DELETE', '/v1/pair');
      expect(blocked.status, 403);
      expect(blocked.errorCode, errorOriginForbidden);
    });
  });

  group('Token', () {
    test('geschützte Route ohne Token gibt 401', () async {
      final response = await send('DELETE', '/v1/pair', origin: kasse);
      expect(response.status, 401);
      expect(response.errorCode, errorUnauthorized);
      expect(
        (response.json['error']! as Map)['message'],
        'Kasse ist nicht gekoppelt.',
      );
    });

    test('falscher Token gibt 401', () async {
      await pair();
      final response = await send(
        'DELETE',
        '/v1/pair',
        origin: kasse,
        token: 'voellig-falsch',
      );
      expect(response.status, 401);
      expect(response.errorCode, errorUnauthorized);
    });

    test('richtiger Token kommt durch', () async {
      final token = await pair();
      final response = await send(
        'DELETE',
        '/v1/pair',
        origin: kasse,
        token: token,
      );
      expect(response.status, 200);
      expect(response.ok, isTrue);
      expect((await store.load()).tokenHashes, isEmpty);
    });

    test('unbekannter Pfad ergibt 404', () async {
      final token = await pair();
      final response = await send(
        'GET',
        '/v1/gibt-es-nicht',
        origin: kasse,
        token: token,
      );
      expect(response.status, 404);
      expect(response.errorCode, errorNotFound);
    });
  });

  group('Status', () {
    test('Kurzform ohne Token', () async {
      now = now.add(const Duration(seconds: 42));
      final response = await send('GET', '/v1/status', origin: kasse);
      final json = response.json;

      expect(json['ok'], isTrue);
      expect(json['version'], agentVersion);
      expect(json['os'], Platform.operatingSystem);
      expect(json['port'], server.port);
      expect(json['paired'], isFalse);
      expect(json['uptimeSeconds'], 42);
      expect(json.containsKey('printers'), isFalse);
      expect(json.containsKey('lastErrors'), isFalse);
    });

    test('Langform mit Token nennt Drucker und letzte Fehler', () async {
      final token = await pair();
      log.error('Drucker nicht erreichbar', 'timeout');

      final response = await send(
        'GET',
        '/v1/status',
        origin: kasse,
        token: token,
      );
      final json = response.json;

      expect(json['paired'], isTrue);
      expect(json['printers'], isEmpty);
      final errors = json['lastErrors']! as List;
      expect(errors, hasLength(1));
      expect(
        (errors.single as Map)['message'],
        'Drucker nicht erreichbar: timeout',
      );
    });

    test('mit falschem Token bleibt es bei der Kurzform', () async {
      await pair();
      final response = await send(
        'GET',
        '/v1/status',
        origin: kasse,
        token: 'falsch',
      );
      expect(response.status, 200);
      expect(response.json['paired'], isTrue);
      expect(response.json.containsKey('printers'), isFalse);
    });
  });

  group('Pairing über die API', () {
    test('richtiger Code liefert einen Token', () async {
      final code = await ctx.pairing.newCode();
      final response = await send(
        'POST',
        '/v1/pair',
        origin: kasse,
        body: <String, Object?>{'code': code},
      );

      expect(response.status, 200);
      expect(response.ok, isTrue);
      final token = response.json['token']! as String;
      expect((await store.load()).tokenHashes, <String>[hashToken(token)]);
    });

    test('falscher Code: 200 mit pair_invalid', () async {
      await ctx.pairing.newCode();
      final response = await send(
        'POST',
        '/v1/pair',
        origin: kasse,
        body: <String, Object?>{'code': '999999'},
      );
      expect(response.status, 200);
      expect(response.ok, isFalse);
      expect(response.errorCode, errorPairInvalid);
    });

    test('abgelaufener Code: pair_expired', () async {
      final code = await ctx.pairing.newCode();
      now = now.add(pairingCodeLifetime + const Duration(seconds: 1));
      final response = await send(
        'POST',
        '/v1/pair',
        origin: kasse,
        body: <String, Object?>{'code': code},
      );
      expect(response.errorCode, errorPairExpired);
    });

    test('fünf Fehlversuche sperren', () async {
      final code = await ctx.pairing.newCode();
      for (var i = 0; i < 5; i++) {
        final response = await send(
          'POST',
          '/v1/pair',
          origin: kasse,
          body: <String, Object?>{'code': '111111'},
        );
        expect(response.errorCode, errorPairInvalid, reason: '$i');
      }
      final locked = await send(
        'POST',
        '/v1/pair',
        origin: kasse,
        body: <String, Object?>{'code': code},
      );
      expect(locked.errorCode, errorPairLocked);
    });

    test('fehlender Code ergibt bad_request', () async {
      final response = await send(
        'POST',
        '/v1/pair',
        origin: kasse,
        body: <String, Object?>{},
      );
      expect(response.errorCode, errorBadRequest);
    });

    test('kaputter Rumpf ergibt bad_request statt Absturz', () async {
      final client = HttpClient();
      final request = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}/v1/pair'),
      );
      request.headers.set('origin', kasse);
      request.headers.contentType = ContentType.json;
      request.write('{kein json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);

      expect(response.statusCode, 200);
      expect(
        ((jsonDecode(body) as Map)['error']! as Map)['code'],
        errorBadRequest,
      );
    });
  });

  group('Kopplung aus der Kasse anstoßen', () {
    const path = '/v1/pair/request';

    test('ist eine öffentliche Route (auch mit abschließendem /)', () {
      expect(isPublicRoute('POST', path), isTrue);
      expect(isPublicRoute('POST', '$path/'), isTrue);
      expect(isPublicRoute('GET', path), isFalse);
    });

    test('erzeugt einen frischen Code und öffnet die Kopplungsseite', () async {
      final response = await send('POST', path, origin: kasse);

      expect(response.status, 200);
      expect(response.ok, isTrue);

      final pairing = (await store.load()).pairing;
      expect(pairing.code, matches(RegExp(r'^\d{6}$')));
      expect(pairing.expiresAt, now.add(pairingCodeLifetime));

      expect(browser.calls, hasLength(1));
      expect(
        browser.calls.single.arguments.last,
        contains('#code=${pairing.code}'),
      );
      expect(
        browser.calls.single.arguments.last,
        contains('&port=${server.port}'),
      );
    });

    test('die Antwort nennt den Code nirgends', () async {
      final response = await send('POST', path, origin: kasse);
      final code = (await store.load()).pairing.code!;

      expect(response.body, isNot(contains(code)));
      expect(response.json.keys, <String>['ok']);
    });

    test('ohne Token erreichbar — genau dafür ist der Endpunkt da', () async {
      final response = await send('POST', path, origin: kasse);
      expect(response.status, 200);
      expect((await store.load()).tokenHashes, isEmpty);
    });

    test('ohne Herkunft (curl) erreichbar', () async {
      final response = await send('POST', path);
      expect(response.status, 200);
      expect(response.ok, isTrue);
      expect(browser.calls, hasLength(1));
    });

    test('fremde Herkunft bekommt 403 und öffnet nichts', () async {
      final response = await send(
        'POST',
        path,
        origin: 'https://boese.example.com',
      );
      expect(response.status, 403);
      expect(response.errorCode, errorOriginForbidden);
      expect(browser.calls, isEmpty);
    });

    test('zweiter Aufruf binnen zehn Sekunden wird gebremst', () async {
      expect((await send('POST', path, origin: kasse)).ok, isTrue);
      now = now.add(const Duration(seconds: 9));

      final second = await send('POST', path, origin: kasse);
      expect(second.status, 200);
      expect(second.ok, isFalse);
      expect(second.errorCode, errorPairRequestThrottled);
      expect(
        (second.json['error']! as Map)['message'],
        'Bitte kurz warten und erneut versuchen.',
      );
      // Kein zweites Browserfenster.
      expect(browser.calls, hasLength(1));
    });

    test('nach zehn Sekunden geht es wieder', () async {
      await send('POST', path, origin: kasse);
      now = now.add(pairRequestMinInterval);

      final second = await send('POST', path, origin: kasse);
      expect(second.ok, isTrue);
      expect(browser.calls, hasLength(2));
      // Frischer Code mit frischer Gültigkeit.
      expect(
        (await store.load()).pairing.expiresAt,
        now.add(pairingCodeLifetime),
      );
    });

    test('funktioniert auch, wenn schon gekoppelt ist', () async {
      await pair();
      expect((await store.load()).tokenHashes, hasLength(1));
      now = now.add(pairRequestMinInterval);

      final response = await send('POST', path, origin: kasse);
      expect(response.ok, isTrue);
      expect(browser.calls, hasLength(1));
      // Der vorhandene Token bleibt gültig.
      expect((await store.load()).tokenHashes, hasLength(1));
    });

    test(
      'KASSENECK_CONNECT_NO_BROWSER=1 öffnet nichts, meldet aber ok',
      () async {
        final quietServer = await shelf_io.serve(
          buildHandler(
            AgentContext(
              store: store,
              log: log,
              startedAt: now,
              clock: () => now,
              environment: const <String, String>{noBrowserEnvVar: '1'},
              pairing: Pairing(
                store: store,
                log: log,
                clock: () => now,
                random: Random(11),
                runProcess: browser.runner,
              ),
            ),
          ),
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => quietServer.close(force: true));

        final client = HttpClient();
        final request = await client.openUrl(
          'POST',
          Uri.parse('http://127.0.0.1:${quietServer.port}$path'),
        );
        request.headers.set('origin', kasse);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        client.close(force: true);

        expect(response.statusCode, 200);
        expect((jsonDecode(body) as Map)['ok'], isTrue);
        expect(browser.calls, isEmpty);
        // Der Code liegt trotzdem bereit — die Konsole zeigt ihn.
        expect((await store.load()).pairing.code, isNotNull);
      },
    );
  });

  test('zusätzliche Routen lassen sich anmelden (A3/A4)', () async {
    final extraServer = await shelf_io.serve(
      buildHandler(
        ctx,
        extraRoutes: <RouteRegistrar>[
          (router, context) => router.get(
            '/v1/printers',
            (_) => okJson(<String, Object?>{'printers': <Object?>[]}),
          ),
        ],
      ),
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => extraServer.close(force: true));

    final token = await pair();
    final client = HttpClient();
    final request = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:${extraServer.port}/v1/printers'),
    );
    request.headers.set('origin', kasse);
    request.headers.set('authorization', 'Bearer $token');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close(force: true);

    expect(response.statusCode, 200);
    expect((jsonDecode(body) as Map)['ok'], isTrue);
  });

  group('Entwicklungsherkünfte', () {
    const dev = 'http://localhost:5173';

    test('sind standardmäßig gesperrt', () async {
      final response = await send('GET', '/v1/status', origin: dev);
      expect(response.status, 403);
      expect(response.errorCode, errorOriginForbidden);
    });

    test('auch 127.0.0.1 ist standardmäßig gesperrt', () async {
      final response = await send(
        'GET',
        '/v1/status',
        origin: 'http://127.0.0.1:4173',
      );
      expect(response.status, 403);
    });

    test('allowDevOrigins in der Konfiguration schaltet sie frei', () async {
      await store.mutate((current) => current.copyWith(allowDevOrigins: true));

      final response = await send('GET', '/v1/status', origin: dev);
      expect(response.status, 200);
      expect(response.headers.value('access-control-allow-origin'), dev);
    });

    test('KASSENECK_CONNECT_DEV=1 schaltet sie frei', () async {
      final devServer = await shelf_io.serve(
        buildHandler(
          ctx,
          environment: const <String, String>{devOriginsEnvVar: '1'},
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => devServer.close(force: true));

      final client = HttpClient();
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${devServer.port}/v1/status'),
      );
      request.headers.set('origin', dev);
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      expect(response.statusCode, 200);
      expect(response.headers.value('access-control-allow-origin'), dev);
    });
  });

  test('zu großer Rumpf wird abgewiesen (413)', () async {
    final response = await send(
      'POST',
      '/v1/pair',
      origin: kasse,
      body: <String, Object?>{'code': '1' * (64 * 1024 + 1)},
    );

    expect(response.status, 413);
    expect(response.errorCode, errorBodyTooLarge);
  });
}
