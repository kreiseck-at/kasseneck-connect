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
  final List<({String methode, String pfad, String rumpf})> aufrufe = [];
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
      'Erreichbarkeitstest fragt /api/terminals und reicht die Antwort durch',
      () async {
        hps.antworten.add((
          status: 200,
          rumpf: '[{"terminalID":"3710016","serialNumber":"SN1"}]',
        ));
        final antwort = await senden('/v1/terminal/test', {
          'host': '127.0.0.1',
          'port': hps.port,
        });

        expect(antwort['ok'], isTrue);
        expect(hps.aufrufe.single.methode, 'GET');
        expect(hps.aufrufe.single.pfad, '/api/terminals');
        final liste = antwort['hps'] as List<Object?>;
        expect((liste.single as Map)['terminalID'], '3710016');
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
