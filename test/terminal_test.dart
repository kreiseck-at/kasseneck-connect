import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Ein Fake-HPS: nimmt die Aufrufe der Brücke entgegen, merkt sie sich und
/// antwortet mit vorgegebenen JSON-Rümpfen — Format wie in der Spec bzw. der
/// Postman-Collection des Pakets `hobex_hps`.
class FakeHps {
  FakeHps(this.server) {
    server.listen((HttpRequest request) async {
      final body = await request
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      aufrufe.add((
        methode: request.method,
        pfad: request.uri.path,
        rumpf: body,
        contentLength: request.headers.contentLength,
      ));
      final antwortJetzt = antworten.isEmpty
          ? (status: 200, rumpf: '{}')
          : antworten.removeAt(0);
      request.response.statusCode = antwortJetzt.status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(antwortJetzt.rumpf);
      await request.response.close();
    });
  }

  final HttpServer server;
  final List<({String methode, String pfad, String rumpf, int contentLength})>
  aufrufe = [];
  final List<({int status, String rumpf})> antworten = [];

  int get port => server.port;

  static Future<FakeHps> starten() async {
    return FakeHps(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  }
}

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late AgentContext ctx;
  late HttpServer server;
  late FakeHps hps;
  late String token;

  const kasse = 'https://kasse.kasseneck.at';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-terminal-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    final now = DateTime(2026, 8, 20, 5);
    final pairing = Pairing(
      store: store,
      log: log,
      clock: () => now,
      random: Random(7),
      runProcess: FakeProcessRunner().runner,
    );
    ctx = AgentContext(
      store: store,
      log: log,
      startedAt: now,
      clock: () => now,
      environment: const <String, String>{},
      pairing: pairing,
    );
    server = await shelf_io.serve(
      buildHandler(ctx, extraRoutes: <RouteRegistrar>[terminalRoutes()]),
      InternetAddress.loopbackIPv4,
      0,
    );
    ctx.port = server.port;
    token = await pairing.issueToken();
    hps = await FakeHps.starten();
  });

  tearDown(() async {
    await server.close(force: true);
    await hps.server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> senden(
    String pfad,
    Map<String, Object?> rumpf, {
    bool mitToken = true,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}$pfad'),
      );
      request.headers.set('origin', kasse);
      if (mitToken) request.headers.set('authorization', 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(rumpf));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return <String, Object?>{
        'status': response.statusCode,
        ...jsonDecode(text) as Map<String, Object?>,
      };
    } finally {
      client.close(force: true);
    }
  }

  group('Terminal-Brücke (Hobex HPS)', () {
    test(
      'Erreichbarkeitstest: TID-lose Probe, Invalid-TID-Antwort = Terminal da',
      () async {
        // Antwort 1:1 vom echten Gerät (hps 1.10.0, 2026-08-20): das HPS kennt
        // GET /api/terminals nicht — nur /api/terminals/{tid}/diagnosis.
        hps.antworten.add((
          status: 200,
          rumpf:
              '{"responseCode":"100108","responseText":"Invalid TID","tid":"0","transactionId":null}',
        ));
        final antwort = await senden('/v1/terminal/test', {
          'host': '127.0.0.1',
          'port': hps.port,
        });

        expect(antwort['ok'], isTrue);
        expect(hps.aufrufe.single.methode, 'GET');
        expect(hps.aufrufe.single.pfad, '/api/terminals/0/diagnosis');
        expect((antwort['hps'] as Map)['responseText'], 'Invalid TID');
      },
    );

    test(
      'Erreichbarkeitstest mit TID: echte Diagnose samt Gerätestatus',
      () async {
        hps.antworten.add((
          status: 200,
          rumpf:
              '{"deviceStatus":"IN_OPERATION","hps":"1.10.0","responseCode":"0","responseText":"Authorized"}',
        ));
        final antwort = await senden('/v1/terminal/test', {
          'host': '127.0.0.1',
          'port': hps.port,
          'tid': '3600335',
        });
        expect(antwort['ok'], isTrue);
        expect(hps.aufrufe.single.pfad, '/api/terminals/3600335/diagnosis');
        expect((antwort['hps'] as Map)['deviceStatus'], 'IN_OPERATION');
      },
    );

    test(
      'etwas anderes auf dem Port (JSON ohne responseCode) ist kein Terminal',
      () async {
        hps.antworten.add((status: 200, rumpf: '{"ich":"bin kein Terminal"}'));
        final antwort = await senden('/v1/terminal/test', {
          'host': '127.0.0.1',
          'port': hps.port,
        });
        expect(antwort['ok'], isFalse);
        expect((antwort['error'] as Map)['code'], 'terminal_error');
        expect((antwort['error'] as Map)['message'], contains('kein'));
      },
    );

    test('Diagnose läuft über /api/terminals/<tid>/diagnosis', () async {
      hps.antworten.add((
        status: 200,
        rumpf: '{"deviceStatus":"IN_OPERATION","responseCode":"0"}',
      ));
      final antwort = await senden('/v1/terminal/diagnosis', {
        'host': '127.0.0.1',
        'port': hps.port,
        'tid': '3710016',
      });
      expect(antwort['ok'], isTrue);
      expect(hps.aufrufe.single.pfad, '/api/terminals/3710016/diagnosis');
      expect((antwort['hps'] as Map)['deviceStatus'], 'IN_OPERATION');
    });

    test(
      'Zahlung: Cent werden zu Euro, Sale-Form stimmt, Antwort unverändert',
      () async {
        hps.antworten.add((
          status: 200,
          rumpf:
              '{"transactionId":"17556661","responseCode":"0","responseText":"Approved","amount":12.34,"brand":"VISA"}',
        ));
        final antwort = await senden('/v1/terminal/payment', {
          'host': '127.0.0.1',
          'port': hps.port,
          'tid': '3710016',
          'amountCents': 1234,
          'tipCents': 100,
          'transactionId': '17556661',
          'reference': 'Beleg 42',
        });

        expect(antwort['ok'], isTrue);
        expect((antwort['hps'] as Map)['responseCode'], '0');

        final anHps = jsonDecode(hps.aufrufe.single.rumpf) as Map;
        final tx = anHps['transaction'] as Map;
        expect(hps.aufrufe.single.pfad, '/api/transaction/payment');
        // Das HPS rechnet in Euro (12.34), die Kasse in Cent (1234).
        expect(tx['amount'], 12.34);
        expect(tx['tip'], 1.0);
        expect(tx['transactionType'], 1);
        expect(tx['tid'], '3710016');
        expect(tx['transactionId'], '17556661');
        expect(tx['currency'], 'EUR');
        expect(tx['reference'], 'Beleg 42');
        // Content-Length MUSS gesetzt sein: chunked versteht der eingebettete
        // HPS-Server nicht und antwortet mit Klartext statt JSON (belegt am
        // echten Geraet — die Zahlung kam dadurch nie an).
        expect(
          hps.aufrufe.single.contentLength,
          utf8.encode(hps.aufrufe.single.rumpf).length,
        );
        expect(hps.aufrufe.single.contentLength, greaterThan(0));
      },
    );

    test(
      'Ablehnung ist KEIN Fehler: ok bleibt true, responseCode spricht',
      () async {
        hps.antworten.add((
          status: 200,
          rumpf:
              '{"transactionId":"1","responseCode":"05","responseText":"Declined"}',
        ));
        final antwort = await senden('/v1/terminal/payment', {
          'host': '127.0.0.1',
          'port': hps.port,
          'tid': '3710016',
          'amountCents': 500,
          'transactionId': '1',
        });
        expect(antwort['ok'], isTrue);
        expect((antwort['hps'] as Map)['responseCode'], '05');
      },
    );

    test(
      'HPS-Fehlerstatus wird deutscher Fehler mit message des Terminals',
      () async {
        hps.antworten.add((
          status: 503,
          rumpf: '{"message":"Terminal not operational"}',
        ));
        final antwort = await senden('/v1/terminal/diagnosis', {
          'host': '127.0.0.1',
          'port': hps.port,
          'tid': '3710016',
        });
        expect(antwort['ok'], isFalse);
        final fehler = antwort['error'] as Map;
        expect(fehler['code'], 'terminal_error');
        expect(fehler['message'], contains('Terminal not operational'));
      },
    );

    test('geschlossener Port: terminal_offline mit deutschem Satz', () async {
      final zu = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final toterPort = zu.port;
      await zu.close(force: true);

      final antwort = await senden('/v1/terminal/test', {
        'host': '127.0.0.1',
        'port': toterPort,
      });
      expect(antwort['ok'], isFalse);
      expect((antwort['error'] as Map)['code'], 'terminal_offline');
      expect(
        (antwort['error'] as Map)['message'],
        contains('nicht erreichbar'),
      );
    });

    test('Status und Abbruch nutzen die Transaktions-Pfade', () async {
      hps.antworten.add((status: 200, rumpf: '{"state":"CLEARED"}'));
      hps.antworten.add((status: 200, rumpf: '{"transactionId":"9"}'));
      await senden('/v1/terminal/status', {
        'host': '127.0.0.1',
        'port': hps.port,
        'tid': '3710016',
        'transactionId': '9',
      });
      await senden('/v1/terminal/abort', {
        'host': '127.0.0.1',
        'port': hps.port,
        'tid': '3710016',
        'transactionId': '9',
      });
      expect(hps.aufrufe[0].methode, 'GET');
      expect(hps.aufrufe[0].pfad, '/api/v2/transactions/3710016/9');
      expect(hps.aufrufe[1].methode, 'POST');
      expect(hps.aufrufe[1].pfad, '/api/transaction/abort/3710016/9');
    });

    test('Terminal-Suche findet das HPS im Netz (Invalid-TID-Probe)', () async {
      hps.antworten.add((
        status: 200,
        rumpf:
            '{"responseCode":"100108","responseText":"Invalid TID","tid":"0","transactionId":null}',
      ));

      final ergebnis = await discoverTerminals(
        bridge: HpsBridge(log: log),
        log: log,
        port: hps.port,
        interfaces: () async => <LocalInterface>[
          // .2 als eigene Adresse: dann wird .1 (der Fake-HPS) gescannt.
          LocalInterface(name: 'lo-test', address: '127.0.0.2'),
        ],
      );

      expect(ergebnis.scanned.single.subnet, '127.0.0.0/24');
      expect(ergebnis.found, hasLength(1));
      expect(ergebnis.found.single.host, '127.0.0.1');
      // Die Probe kennt die TID nicht — sie steht im Vertrag/Panel.
      expect(ergebnis.found.single.tids, isEmpty);
    });

    test('ein fremder Dienst auf dem HPS-Port ist kein Treffer', () async {
      // Der Port ist offen, aber die Probe antwortet nicht im HPS-Format —
      // Router-UIs und Kameras lauschen auch auf 8080.
      hps.antworten.add((status: 200, rumpf: '{"ich":"bin kein Terminal"}'));

      final ergebnis = await discoverTerminals(
        bridge: HpsBridge(log: log),
        log: log,
        port: hps.port,
        interfaces: () async => <LocalInterface>[
          LocalInterface(name: 'lo-test', address: '127.0.0.2'),
        ],
      );

      expect(ergebnis.found, isEmpty);
      expect(ergebnis.scanned, hasLength(1));
    });

    test('Suche über die API: Route liefert found/scanned durch', () async {
      final eigenerServer = await shelf_io.serve(
        buildHandler(
          ctx,
          extraRoutes: <RouteRegistrar>[
            terminalRoutes(
              discover: (h, c) async => TerminalDiscoveryResult(
                found: <DiscoveredTerminal>[
                  DiscoveredTerminal(
                    host: '192.168.0.99',
                    port: 8080,
                    tids: <String>['3710016'],
                  ),
                ],
                scanned: <ScannedSubnet>[
                  ScannedSubnet(
                    interface: 'en0',
                    subnet: '192.168.0.0/24',
                    hosts: 253,
                  ),
                ],
              ),
            ),
          ],
        ),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => eigenerServer.close(force: true));

      final client = HttpClient();
      final request = await client.openUrl(
        'POST',
        Uri.parse(
          'http://127.0.0.1:${eigenerServer.port}/v1/terminal/discover',
        ),
      );
      request.headers.set('origin', kasse);
      request.headers.set('authorization', 'Bearer $token');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      client.close(force: true);

      final daten = jsonDecode(text) as Map;
      expect(daten['ok'], isTrue);
      final fund = (daten['found'] as List).single as Map;
      expect(fund['host'], '192.168.0.99');
      expect(fund['tids'], <Object?>['3710016']);
      expect(
        (daten['scanned'] as List).single,
        containsPair('subnet', '192.168.0.0/24'),
      );
    });

    test('ohne Token 401 — das Terminal ist kein öffentlicher Pfad', () async {
      final antwort = await senden('/v1/terminal/test', {
        'host': '127.0.0.1',
        'port': hps.port,
      }, mitToken: false);
      expect(antwort['status'], 401);
      expect(hps.aufrufe, isEmpty);
    });

    test(
      'Unsinn wird abgewiesen, bevor irgendetwas das Netz berührt',
      () async {
        final faelle = <Map<String, Object?>>[
          <String, Object?>{'port': hps.port}, // host fehlt
          <String, Object?>{'host': 'kaputt/../pfad', 'port': hps.port},
          <String, Object?>{'host': '127.0.0.1', 'port': 0},
          <String, Object?>{
            // Betrag fehlt
            'host': '127.0.0.1', 'port': hps.port,
            'tid': '1', 'transactionId': '1',
          },
        ];
        for (final rumpf in faelle.take(3)) {
          final antwort = await senden('/v1/terminal/test', rumpf);
          expect(antwort['ok'], isFalse, reason: '$rumpf');
          expect((antwort['error'] as Map)['code'], 'bad_request');
        }
        final zahlung = await senden('/v1/terminal/payment', faelle.last);
        expect((zahlung['error'] as Map)['code'], 'bad_request');
        expect(hps.aufrufe, isEmpty);
      },
    );
  });
}
