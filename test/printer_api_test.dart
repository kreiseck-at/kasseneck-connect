import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/fake_printer.dart';

/// Antwort in bequemer Form.
class ApiResponse {
  ApiResponse(this.status, this.body);

  final int status;
  final String body;

  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;

  bool get ok => json['ok'] == true;

  String? get errorCode {
    final error = json['error'];
    return error is Map ? error['code'] as String? : null;
  }

  List<Map<String, Object?>> get printers =>
      (json['printers']! as List).cast<Map<String, Object?>>().toList();
}

void main() {
  const kasse = 'https://kasse.kasseneck.at';
  const token = 'geheim-token';

  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late EventBus bus;
  late PrinterRegistry registry;
  late PrintQueue queue;
  late HttpServer server;
  late List<bool> discoveryScans;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-printer-api-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    bus = EventBus();
    registry = PrinterRegistry(
      store: store,
      log: log,
      events: bus,
      random: Random(4),
    );
    queue = PrintQueue(registry: registry, events: bus, log: log);
    discoveryScans = <bool>[];

    final discovery = _RecordingDiscovery(discoveryScans);
    final ctx = AgentContext(
      store: store,
      log: log,
      startedAt: DateTime(2026, 8, 19, 9),
      events: bus,
      printers: registry.summaries,
    );
    server = await shelf_io.serve(
      buildHandler(
        ctx,
        extraRoutes: <RouteRegistrar>[
          printerRoutes(registry: registry, queue: queue, discovery: discovery),
        ],
      ),
      InternetAddress.loopbackIPv4,
      0,
    );
    ctx.port = server.port;

    await store.mutate(
      (config) => config.copyWith(tokenHashes: <String>[hashToken(token)]),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await bus.close();
    temp.deleteSync(recursive: true);
  });

  Future<ApiResponse> send(
    String method,
    String path, {
    Object? body,
    bool withToken = true,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      request.headers.set('origin', kasse);
      if (withToken) request.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        final raw = body is String ? body : jsonEncode(body);
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(raw));
      }
      final response = await request.close();
      return ApiResponse(
        response.statusCode,
        await utf8.decoder.bind(response).join(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<String> addPrinter(int port, {String name = 'Kasse vorne'}) async {
    final response = await send(
      'PUT',
      '/v1/printers',
      body: <String, Object?>{
        'name': name,
        'kind': 'tcp9100',
        'host': '127.0.0.1',
        'port': port,
      },
    );
    return (response.json['printer']! as Map<String, Object?>)['id']! as String;
  }

  group('Drucker verwalten', () {
    test('ohne Token bleibt alles verschlossen', () async {
      expect((await send('GET', '/v1/printers', withToken: false)).status, 401);
      expect(
        (await send(
          'PUT',
          '/v1/printers',
          withToken: false,
          body: <String, Object?>{'kind': 'tcp9100', 'host': '1.2.3.4'},
        )).status,
        401,
      );
      expect(
        (await send(
          'POST',
          '/v1/print',
          withToken: false,
          body: <String, Object?>{
            'printerId': 'p_x',
            'jobId': 'j',
            'bytes': 'AA==',
          },
        )).status,
        401,
      );
      expect((await store.load()).printers, isEmpty);
    });

    test('PUT ohne ID legt an, der Agent vergibt die ID', () async {
      final response = await send(
        'PUT',
        '/v1/printers',
        body: <String, Object?>{
          'name': 'Kasse vorne',
          'kind': 'tcp9100',
          'host': '192.168.0.50',
        },
      );

      expect(response.ok, isTrue);
      final printer = response.json['printer']! as Map<String, Object?>;
      expect(printer['id'], matches(RegExp(r'^p_[a-z2-7]{8}$')));
      expect(printer['port'], 9100);
      expect((await store.load()).printers.single.host, '192.168.0.50');
    });

    test('PUT auf /neu vergibt eine ID statt sie zu übernehmen', () async {
      final response = await send(
        'PUT',
        '/v1/printers/neu',
        body: <String, Object?>{
          'name': 'Kasse vorne',
          'kind': 'tcp9100',
          'host': '192.168.0.136',
          'port': 9100,
        },
      );

      expect(response.ok, isTrue);
      final printer = response.json['printer']! as Map<String, Object?>;
      expect(printer['id'], matches(RegExp(r'^p_[a-z2-7]{8}$')));
      expect((await store.load()).printers.single.id, printer['id']);
      expect(
        (await store.load()).printers.single.id,
        isNot('neu'),
        reason: 'die Kasse meint „neu", nicht eine ID namens neu',
      );
    });

    test('zwei Mal /neu mit anderer Adresse ergibt zwei Drucker', () async {
      Future<String> put(String host) async =>
          ((await send(
                    'PUT',
                    '/v1/printers/neu',
                    body: <String, Object?>{
                      'name': 'Drucker $host',
                      'kind': 'tcp9100',
                      'host': host,
                      'port': 9100,
                    },
                  )).json['printer']!
                  as Map<String, Object?>)['id']!
              as String;

      final a = await put('192.168.0.136');
      final b = await put('192.168.0.137');

      expect(a, isNot(b));
      expect((await store.load()).printers, hasLength(2));
    });

    test('/neu mit bekannter Adresse aktualisiert statt zu doppeln', () async {
      final first = await send(
        'PUT',
        '/v1/printers/neu',
        body: <String, Object?>{
          'name': 'Kasse vorne',
          'kind': 'tcp9100',
          'host': '192.168.0.136',
          'port': 9100,
        },
      );
      final again = await send(
        'PUT',
        '/v1/printers/neu',
        body: <String, Object?>{
          'name': 'Kasse vorne, Bonrolle',
          'kind': 'tcp9100',
          'host': '192.168.0.136',
          'port': 9100,
        },
      );

      final id = (first.json['printer']! as Map<String, Object?>)['id'];
      expect((again.json['printer']! as Map<String, Object?>)['id'], id);
      final printers = (await store.load()).printers;
      expect(printers, hasLength(1));
      expect(printers.single.name, 'Kasse vorne, Bonrolle');
    });

    test('PUT mit ID ändert den vorhandenen Eintrag', () async {
      final id = await addPrinter(9100);

      final response = await send(
        'PUT',
        '/v1/printers/$id',
        body: <String, Object?>{
          'name': 'Küche',
          'kind': 'epos',
          'host': '192.168.0.51',
          'devid': 'local_printer2',
        },
      );

      expect(response.ok, isTrue);
      final printers = (await store.load()).printers;
      expect(printers, hasLength(1));
      expect(printers.single.name, 'Küche');
      expect(printers.single.kind, PrinterKind.epos);
      expect(printers.single.devid, 'local_printer2');
      expect(printers.single.port, 80, reason: 'Standardport der Anbindung');
    });

    test('unbrauchbare Angaben ergeben bad_request', () async {
      Future<String?> put(Map<String, Object?> body) async =>
          (await send('PUT', '/v1/printers', body: body)).errorCode;

      expect(
        await put(<String, Object?>{'kind': 'lpd', 'host': '1.2.3.4'}),
        errorBadRequest,
      );
      expect(
        await put(<String, Object?>{'kind': 'tcp9100', 'host': ''}),
        errorBadRequest,
      );
      expect(
        await put(<String, Object?>{
          'kind': 'tcp9100',
          'host': '1.2.3.4',
          'port': 70000,
        }),
        errorBadRequest,
      );
      expect((await store.load()).printers, isEmpty);
    });

    test('GET liefert die Drucker samt Zustand', () async {
      final fake = await FakeTcpPrinter.start();
      addTearDown(fake.stop);
      final id = await addPrinter(fake.port);

      final response = await send('GET', '/v1/printers');

      expect(response.ok, isTrue);
      expect(response.printers.single['id'], id);
      expect(response.printers.single['state'], 'online');
      expect(
        (await send('GET', '/v1/printers?probe=0')).printers.single['state'],
        'online',
        reason: 'zuletzt bekannter Zustand',
      );
    });

    test(
      'DELETE entfernt den Drucker, unbekannt ergibt printer_unknown',
      () async {
        final id = await addPrinter(9100);

        expect((await send('DELETE', '/v1/printers/$id')).ok, isTrue);
        expect((await store.load()).printers, isEmpty);
        expect(
          (await send('DELETE', '/v1/printers/$id')).errorCode,
          errorPrinterUnknown,
        );
      },
    );

    test('Status in der Langform führt die Drucker mit', () async {
      final id = await addPrinter(9100);

      final status = await send('GET', '/v1/status');

      expect(status.printers.single['id'], id);
      expect(status.printers.single['state'], 'unknown');
    });
  });

  group('Drucken', () {
    test('Testseite geht an den Drucker', () async {
      final fake = await FakeTcpPrinter.start();
      addTearDown(fake.stop);
      final id = await addPrinter(fake.port);
      final bytes = Uint8List.fromList(<int>[0x1b, 0x40, 84, 69, 83, 84]);

      final response = await send(
        'POST',
        '/v1/printers/$id/test',
        body: <String, Object?>{'bytes': base64Encode(bytes)},
      );

      expect(response.ok, isTrue);
      expect(response.json['jobId'], isA<String>());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.received, bytes);
    });

    test('POST /v1/print druckt und ist je jobId idempotent', () async {
      final fake = await FakeTcpPrinter.start();
      addTearDown(fake.stop);
      final id = await addPrinter(fake.port);
      final bytes = Uint8List.fromList(<int>[65, 66, 67]);
      final body = <String, Object?>{
        'printerId': id,
        'jobId': 'bon-4711',
        'bytes': base64Encode(bytes),
      };

      expect((await send('POST', '/v1/print', body: body)).ok, isTrue);
      expect((await send('POST', '/v1/print', body: body)).ok, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.received, bytes, reason: 'nur ein Bon');
      expect(fake.connections, 1);
    });

    test('derselbe jobId an zwei Druckern druckt auf beiden', () async {
      final vorne = await FakeTcpPrinter.start();
      final kueche = await FakeTcpPrinter.start();
      addTearDown(vorne.stop);
      addTearDown(kueche.stop);
      final a = await addPrinter(vorne.port);
      final b = await addPrinter(kueche.port, name: 'Küche');
      final bytes = base64Encode(Uint8List.fromList(<int>[65, 66]));

      expect(
        (await send(
          'POST',
          '/v1/print',
          body: <String, Object?>{
            'printerId': a,
            'jobId': 'bon-9',
            'bytes': bytes,
          },
        )).ok,
        isTrue,
      );
      expect(
        (await send(
          'POST',
          '/v1/print',
          body: <String, Object?>{
            'printerId': b,
            'jobId': 'bon-9',
            'bytes': bytes,
          },
        )).ok,
        isTrue,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(vorne.received, <int>[65, 66]);
      expect(kueche.received, <int>[65, 66], reason: 'die Küche druckt auch');
    });

    test('unbekannter Drucker und Unsinn im Rumpf', () async {
      expect(
        (await send(
          'POST',
          '/v1/print',
          body: <String, Object?>{
            'printerId': 'p_gibtsnicht',
            'jobId': 'j1',
            'bytes': 'QUJD',
          },
        )).errorCode,
        errorPrinterUnknown,
      );
      expect(
        (await send(
          'POST',
          '/v1/print',
          body: <String, Object?>{
            'printerId': 'p_x',
            'jobId': 'j1',
            'bytes': 'kein base64!!',
          },
        )).errorCode,
        errorBadRequest,
      );
      expect(
        (await send(
          'POST',
          '/v1/print',
          body: <String, Object?>{'jobId': 'j1', 'bytes': 'QUJD'},
        )).errorCode,
        errorBadRequest,
      );
    });

    test('nicht erreichbarer Drucker ergibt printer_offline', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final id = await addPrinter(port);

      final response = await send(
        'POST',
        '/v1/print',
        body: <String, Object?>{
          'printerId': id,
          'jobId': 'bon-1',
          'bytes': 'QUJD',
        },
      );

      expect(response.status, 200);
      expect(response.errorCode, errorPrinterOffline);
      final error = response.json['error']! as Map<String, Object?>;
      expect(error['message'], contains('nicht erreichbar'));

      // Der Zusatz des Treibers geht mit: ohne ihn stünde in der Kasse nur
      // „printer_offline", und der Support müsste raten, was das
      // Betriebssystem gemeldet hat.
      final detail = error['detail']! as Map<String, Object?>;
      expect(detail['jobId'], 'bon-1');
      expect(detail['reason'], isA<String>());
      expect(detail['reason'] as String, isNotEmpty);
      expect(
        log.file.readAsStringSync(),
        contains('Auftrag bon-1'),
        reason: 'dieselbe Angabe steht im Log',
      );
    });

    test('ein großer Bon (über der Standardgrenze) geht durch', () async {
      final fake = await FakeTcpPrinter.start();
      addTearDown(fake.stop);
      final id = await addPrinter(fake.port);
      // 96 KB roh sind base64 rund 128 KB — deutlich über den 64 KB, die für
      // die übrigen Endpunkte gelten.
      final bytes = Uint8List(96 * 1024);

      final response = await send(
        'POST',
        '/v1/print',
        body: <String, Object?>{
          'printerId': id,
          'jobId': 'bon-gross',
          'bytes': base64Encode(bytes),
        },
      );

      expect(response.ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fake.received, hasLength(bytes.length));
    });

    test('die Grenze liegt bei 4 MB', () {
      expect(printBodyLimit, 4 * 1024 * 1024);
    });

    test('über 4 MB wird abgewiesen', () async {
      // Ohne Server: ein 4-MB-Rumpf über die Leitung bliebe stecken, sobald
      // der Agent zu lesen aufhört — der Handler ist die Stelle, die zählt.
      final response = await handlePrint(
        queue,
        Request(
          'POST',
          Uri.parse('http://127.0.0.1/v1/print'),
          body: 'x' * (printBodyLimit + 1024),
        ),
      );

      expect(response.statusCode, 413);
      expect(
        jsonDecode(await response.readAsString()),
        containsPair('error', containsPair('code', errorBodyTooLarge)),
      );
    });
  });

  group('Suche', () {
    test('discover ohne Rumpf sucht ohne Scan', () async {
      final response = await send('POST', '/v1/printers/discover');

      expect(response.ok, isTrue);
      expect(discoveryScans, <bool>[false]);
      expect(response.printers.single['host'], '192.168.0.50');
      expect(response.printers.single['kind'], 'tcp9100');
      expect(response.json['scanned'], isEmpty);
    });

    test('discover reicht scan:true durch und nennt die Netze', () async {
      final response = await send(
        'POST',
        '/v1/printers/discover',
        body: <String, Object?>{'scan': true},
      );

      expect(response.ok, isTrue);
      expect(discoveryScans, <bool>[true]);
      expect(response.json['scanned'], <Map<String, Object?>>[
        <String, Object?>{
          'interface': 'en0',
          'subnet': '192.168.0.0/24',
          'hosts': 253,
        },
      ]);
    });
  });
}

/// Suche, die nichts tut, aber protokolliert, ob gescannt werden sollte.
class _RecordingDiscovery implements PrinterDiscovery {
  _RecordingDiscovery(this.scans);

  final List<bool> scans;

  @override
  Duration get mdnsTimeout => defaultMdnsTimeout;

  @override
  Duration get scanTimeout => defaultScanTimeout;

  @override
  Duration get scanBudget => defaultScanBudget;

  @override
  int get scanConcurrency => defaultScanConcurrency;

  @override
  int get scanPort => rawPrintPort;

  @override
  Future<DiscoveryResult> discover({bool scan = false}) async {
    scans.add(scan);
    return DiscoveryResult(
      printers: const <DiscoveredPrinter>[
        DiscoveredPrinter(
          host: '192.168.0.50',
          port: 9100,
          kind: PrinterKind.tcp9100,
          name: 'TM-T20',
        ),
      ],
      scanned: scan
          ? const <ScannedSubnet>[
              ScannedSubnet(
                interface: 'en0',
                subnet: '192.168.0.0/24',
                hosts: 253,
              ),
            ]
          : const <ScannedSubnet>[],
    );
  }
}
