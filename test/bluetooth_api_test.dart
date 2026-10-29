import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Handler, Request;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/fake_bluetooth.dart';

/// Ein Gerät, das zwar eine gültige Kennung hat, aber nie zugelassen wurde
/// (erfunden).
const String _fremdeId = '8a7b6c5d-4e3f-4a1b-9c8d-7e6f5a4b3c2d';

const String _kasse = 'https://kasse.kasseneck.at';
const String _token = 'bluetooth-token';

final String _ff00 = canonicalUuid('ff00');
final String _ff01 = canonicalUuid('ff01');
final String _ff02 = canonicalUuid('ff02');
final String _ff03 = canonicalUuid('ff03');

/// Antwort in bequemer Form.
class ApiResponse {
  ApiResponse(this.status, this.body);

  final int status;
  final String body;

  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;

  bool get ok => json['ok'] == true;

  Map<String, Object?>? get error => json['error'] as Map<String, Object?>?;

  String? get errorCode => error?['code'] as String?;
}

/// Schickt eine Anfrage an `127.0.0.1:<port>`.
Future<ApiResponse> _send(
  int port,
  String method,
  String path, {
  Object? body,
  bool withToken = true,
  String? origin = _kasse,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (origin != null) request.headers.set('origin', origin);
    if (withToken) request.headers.set('authorization', 'Bearer $_token');
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

String _b64(List<int> bytes) => base64Encode(bytes);

String _hex(String base64) => base64Decode(
  base64,
).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Wartet, bis [bedingung] gilt (höchstens [grenze]).
Future<void> _warteBis(
  FutureOr<bool> Function() bedingung, {
  Duration grenze = const Duration(seconds: 3),
}) async {
  final ende = DateTime.now().add(grenze);
  while (!await bedingung()) {
    if (DateTime.now().isAfter(ende)) {
      fail('Bedingung nach ${grenze.inMilliseconds} ms nicht erfüllt');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-bt-api-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    await store.mutate(
      (config) => config.copyWith(tokenHashes: <String>[hashToken(_token)]),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('Bluetooth-Endpunkte', () {
    late EventBus bus;
    late FakeM110 m110;
    late FakeBluetoothHelper fake;
    late BluetoothBridge bridge;
    late Handler handler;
    late HttpServer server;

    setUp(() async {
      bus = EventBus();
      m110 = FakeM110(fertigNach: const Duration(milliseconds: 50));
      fake = FakeBluetoothHelper(log: log, geraete: [m110]);
      bridge = BluetoothBridge(
        store: store,
        log: log,
        events: bus,
        helper: fake,
      );
      final ctx = AgentContext(
        store: store,
        log: log,
        startedAt: DateTime(2026, 10, 29, 9),
        events: bus,
        bluetooth: bridge,
      );
      handler = buildHandler(
        ctx,
        extraRoutes: <RouteRegistrar>[bluetoothRoutes(bridge: bridge)],
      );
      server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      ctx.port = server.port;
    });

    tearDown(() async {
      await server.close(force: true);
      await bridge.close();
      await bus.close();
    });

    Future<ApiResponse> send(
      String method,
      String path, {
      Object? body,
      bool withToken = true,
      String? origin = _kasse,
    }) => _send(
      server.port,
      method,
      path,
      body: body,
      withToken: withToken,
      origin: origin,
    );

    Future<void> zulassen([String id = fakeM110Id]) async {
      final response = await send(
        'PUT',
        '/v1/bluetooth/devices/$id',
        body: const <String, Object?>{},
      );
      expect(response.ok, isTrue, reason: response.body);
    }

    test('ohne Token 401, fremde Herkunft 403', () async {
      final ohneToken = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/connect',
        withToken: false,
      );
      expect(ohneToken.status, 401);
      expect(ohneToken.errorCode, errorUnauthorized);

      final fremd = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/connect',
        origin: 'https://boese.example',
      );
      expect(fremd.status, 403);
      expect(fremd.errorCode, errorOriginForbidden);

      final ohneHerkunft = await send('GET', '/v1/bluetooth', origin: null);
      expect(ohneHerkunft.status, 403);

      // Keiner der abgewiesenen Aufrufe hat Bluetooth auch nur gestartet.
      expect(fake.starts, 0);
      expect((await store.load()).bluetoothDevices, isEmpty);
    });

    test('scan → approve → connect → lease → write → notifications', () async {
      m110.werte[_ff01] = Uint8List.fromList(const [0x4b, 0x45]);

      final vorher = await send('GET', '/v1/bluetooth');
      expect(vorher.ok, isTrue);
      expect(vorher.json['state'], 'unknown');
      expect(vorher.json['devices'], isEmpty);
      expect(fake.starts, 0, reason: 'der Zustand startet Bluetooth nicht');

      final suche = await send(
        'POST',
        '/v1/bluetooth/scan',
        body: const <String, Object?>{'durationMs': 1000},
      );
      expect(suche.ok, isTrue, reason: suche.body);
      expect(suche.json['devices'], [
        <String, Object?>{
          'id': fakeM110Id,
          'name': 'Q199E00000',
          'rssi': -58,
          'services': [_ff00],
          'approved': false,
        },
      ]);

      // Groß geschriebene Kennung: gespeichert wird klein.
      final zugelassen = await send(
        'PUT',
        '/v1/bluetooth/devices/${fakeM110Id.toUpperCase()}',
        body: const <String, Object?>{},
      );
      expect(zugelassen.ok, isTrue, reason: zugelassen.body);
      final device = zugelassen.json['device']! as Map<String, Object?>;
      expect(device['id'], fakeM110Id);
      expect(device['name'], 'Q199E00000');
      expect(device['connected'], isFalse);

      final verbunden = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/connect',
      );
      expect(verbunden.ok, isTrue, reason: verbunden.body);
      expect(verbunden.json['connected'], isTrue);
      expect(verbunden.json['generation'], 1);

      final gatt = await send('GET', '/v1/bluetooth/devices/$fakeM110Id/gatt');
      expect(gatt.ok, isTrue, reason: gatt.body);
      expect(gatt.json['services'], [
        <String, Object?>{
          'uuid': _ff00,
          'characteristics': [
            <String, Object?>{
              'uuid': _ff01,
              'properties': ['read'],
            },
            <String, Object?>{
              'uuid': _ff02,
              'properties': ['write', 'writeWithoutResponse'],
            },
            <String, Object?>{
              'uuid': _ff03,
              'properties': ['notify'],
            },
          ],
        },
      ]);

      final gelesen = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/read',
        body: const <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff01',
        },
      );
      expect(gelesen.ok, isTrue, reason: gelesen.body);
      expect(_hex(gelesen.json['data']! as String), '4b 45');

      final abo = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/subscribe',
        body: const <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff03',
        },
      );
      expect(abo.ok, isTrue, reason: abo.body);

      final belegt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease',
        body: const <String, Object?>{'waitMs': 1000},
      );
      expect(belegt.ok, isTrue, reason: belegt.body);
      final lease = belegt.json['lease']! as String;
      expect(lease, isNotEmpty);
      expect(belegt.json['ttlMs'], 5000);

      final erneuert = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease/renew',
        body: <String, Object?>{'lease': lease},
      );
      expect(erneuert.ok, isTrue, reason: erneuert.body);

      final mehrere = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/write',
        body: <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff02',
          'withResponse': true,
          'lease': lease,
          'packets': [
            _b64(const [0x10, 0xff]),
            _b64(const [0x1b, 0x40, 0x00]),
          ],
          'generation': 1,
        },
      );
      expect(mehrere.ok, isTrue, reason: mehrere.body);
      expect(mehrere.json['written'], 2);

      final eines = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/write',
        body: <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff02',
          'withResponse': true,
          'lease': lease,
          'data': _b64(const [0x1d, 0x0c]),
        },
      );
      expect(eines.ok, isTrue, reason: eines.body);
      expect(eines.json['written'], 1);
      expect(m110.pakete.map((paket) => paket.toList()), [
        [0x10, 0xff],
        [0x1b, 0x40, 0x00],
        [0x1d, 0x0c],
      ]);

      // Nach dem letzten Paket meldet der Drucker „fertig“.
      await _warteBis(() => m110.etiketten == 1);
      final meldungen = await send(
        'GET',
        '/v1/bluetooth/devices/$fakeM110Id/notifications',
      );
      expect(meldungen.ok, isTrue, reason: meldungen.body);
      expect(meldungen.json['generation'], 1);
      final eintraege = (meldungen.json['notifications']! as List)
          .cast<Map<String, Object?>>();
      expect(eintraege.map((e) => _hex(e['data']! as String)), [
        '02 b6 00',
        '01 01',
        '01 01',
        '01 01',
        '1a 0f 0c',
      ]);
      expect(eintraege.map((e) => e['seq']), [1, 2, 3, 4, 5]);
      for (final eintrag in eintraege) {
        expect(eintrag['service'], _ff00);
        expect(eintrag['characteristic'], _ff03);
        expect(eintrag['generation'], 1);
      }

      final freigegeben = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease/release',
        body: <String, Object?>{'lease': lease},
      );
      expect(freigegeben.ok, isTrue, reason: freigegeben.body);
      expect(freigegeben.json['released'], isTrue);

      // Ein zweites Freigeben (z. B. ein wiederholter Aufruf) ist kein Fehler.
      final nochmalFrei = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease/release',
        body: <String, Object?>{'lease': lease},
      );
      expect(nochmalFrei.status, 200);
      expect(nochmalFrei.json, <String, Object?>{
        'ok': true,
        'released': false,
      });

      // Nach der Freigabe gilt die Belegung nicht mehr.
      final ohneBelegung = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/write',
        body: <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff02',
          'withResponse': true,
          'lease': lease,
          'data': _b64(const [0x00]),
        },
      );
      expect(ohneBelegung.errorCode, errorBluetoothLeaseRequired);
      expect(
        ohneBelegung.error!['message'],
        bluetoothErrorMessages[errorBluetoothLeaseRequired],
      );
      expect(ohneBelegung.status, 200);
      expect(m110.pakete, hasLength(3));

      final abbestellt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/unsubscribe',
        body: const <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff03',
        },
      );
      expect(abbestellt.ok, isTrue, reason: abbestellt.body);
      expect(m110.abonniert, isFalse);

      final zustand = await send('GET', '/v1/bluetooth');
      expect(zustand.json['state'], 'poweredOn');
      final geraete = (zustand.json['devices']! as List)
          .cast<Map<String, Object?>>();
      expect(geraete.single['id'], fakeM110Id);
      expect(geraete.single['connected'], isTrue);
      expect(geraete.single['generation'], 1);

      final getrennt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/release',
      );
      expect(getrennt.ok, isTrue, reason: getrennt.body);
      await _warteBis(() => !m110.verbunden);

      final vergessen = await send(
        'DELETE',
        '/v1/bluetooth/devices/$fakeM110Id',
      );
      expect(vergessen.ok, isTrue, reason: vergessen.body);
      expect(vergessen.json['id'], fakeM110Id);
      expect((await store.load()).bluetoothDevices, isEmpty);

      final nochmal = await send('DELETE', '/v1/bluetooth/devices/$fakeM110Id');
      expect(nochmal.errorCode, errorBluetoothDeviceUnknown);
    });

    test('kaputte Geräte-ID im Pfad: bad_request', () async {
      const kaputt = 'kein-geraet';
      final aufrufe = <(String, String)>[
        ('PUT', '/v1/bluetooth/devices/$kaputt'),
        ('DELETE', '/v1/bluetooth/devices/$kaputt'),
        ('POST', '/v1/bluetooth/devices/$kaputt/connect'),
        ('POST', '/v1/bluetooth/devices/$kaputt/release'),
        ('GET', '/v1/bluetooth/devices/$kaputt/gatt'),
        ('POST', '/v1/bluetooth/devices/$kaputt/read'),
        ('POST', '/v1/bluetooth/devices/$kaputt/write'),
        ('POST', '/v1/bluetooth/devices/$kaputt/subscribe'),
        ('POST', '/v1/bluetooth/devices/$kaputt/unsubscribe'),
        ('GET', '/v1/bluetooth/devices/$kaputt/notifications'),
        ('POST', '/v1/bluetooth/devices/$kaputt/lease'),
        ('POST', '/v1/bluetooth/devices/$kaputt/lease/renew'),
        ('POST', '/v1/bluetooth/devices/$kaputt/lease/release'),
      ];
      for (final (method, path) in aufrufe) {
        final response = await send(
          method,
          path,
          body: method == 'GET' || method == 'DELETE'
              ? null
              : const <String, Object?>{},
        );
        expect(response.status, 200, reason: '$method $path');
        expect(response.errorCode, errorBadRequest, reason: '$method $path');
        expect(response.error!['message'], isNotEmpty, reason: '$method $path');
      }
      expect(fake.starts, 0);
      expect((await store.load()).bluetoothDevices, isEmpty);
    });

    test('nicht zugelassenes Gerät: Meldungen und Belegung '
        'bluetooth_device_unknown', () async {
      await zulassen();
      // Rot-Probe der Zulassung: die Brücke selbst prüft für Meldungen und
      // Erneuern nicht, ob das Gerät zugelassen ist.
      final aufrufe = <(String, String, Object?)>[
        ('GET', '/v1/bluetooth/devices/$_fremdeId/notifications', null),
        (
          'POST',
          '/v1/bluetooth/devices/$_fremdeId/lease/renew',
          const <String, Object?>{'lease': 'AAAAAAAAAAAAAAAAAAAAAA'},
        ),
        ('POST', '/v1/bluetooth/devices/$_fremdeId/connect', null),
        ('POST', '/v1/bluetooth/devices/$_fremdeId/lease', null),
      ];
      for (final (method, path, body) in aufrufe) {
        final response = await send(method, path, body: body);
        expect(
          response.errorCode,
          errorBluetoothDeviceUnknown,
          reason: '$method $path',
        );
        expect(
          response.error!['message'],
          bluetoothErrorMessages[errorBluetoothDeviceUnknown],
        );
      }
      expect(fake.starts, 0);
    });

    test('Freigeben ist wiederholbar: auch nach dem Vergessen und für '
        'unbekannte Geräte ok mit released false', () async {
      await zulassen();
      final belegt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease',
        body: const <String, Object?>{},
      );
      final lease = belegt.json['lease']! as String;

      final vergessen = await send(
        'DELETE',
        '/v1/bluetooth/devices/$fakeM110Id',
      );
      expect(vergessen.ok, isTrue, reason: vergessen.body);

      // Die Kasse gibt nach dem Druck frei, auch wenn das Gerät inzwischen
      // vergessen wurde: das darf nicht scheitern.
      final nachVergessen = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease/release',
        body: <String, Object?>{'lease': lease},
      );
      expect(nachVergessen.status, 200);
      expect(nachVergessen.json, <String, Object?>{
        'ok': true,
        'released': false,
      });

      final unbekannt = await send(
        'POST',
        '/v1/bluetooth/devices/$_fremdeId/lease/release',
        body: const <String, Object?>{'lease': 'AAAAAAAAAAAAAAAAAAAAAA'},
      );
      expect(unbekannt.json, <String, Object?>{'ok': true, 'released': false});

      // Kaputte Anfragen bleiben kaputt.
      final ohneLease = await send(
        'POST',
        '/v1/bluetooth/devices/$_fremdeId/lease/release',
        body: const <String, Object?>{},
      );
      expect(ohneLease.errorCode, errorBadRequest);
      expect(fake.starts, 0);
    });

    test('unbrauchbarer Rumpf: bad_request mit deutschem Text', () async {
      await zulassen();
      final belegt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease',
        body: const <String, Object?>{},
      );
      final lease = belegt.json['lease']! as String;

      Map<String, Object?> schreiben(Map<String, Object?> extra) =>
          <String, Object?>{
            'service': 'ff00',
            'characteristic': 'ff02',
            'withResponse': true,
            'lease': lease,
            'data': _b64(const [0x01]),
            ...extra,
          }..removeWhere((_, value) => value == null);

      final faelle = <String, (String, Object)>{
        'UUID beim Lesen': (
          'read',
          const <String, Object?>{
            'service': 'kein-dienst',
            'characteristic': 'ff01',
          },
        ),
        'UUID beim Abo': (
          'subscribe',
          const <String, Object?>{'service': 'ff00', 'characteristic': 'zzzz'},
        ),
        'Dienst fehlt': (
          'unsubscribe',
          const <String, Object?>{'characteristic': 'ff03'},
        ),
        'UUID beim Schreiben': (
          'write',
          schreiben(const <String, Object?>{'characteristic': '12345'}),
        ),
        'kaputtes Base64 in data': (
          'write',
          schreiben(const <String, Object?>{'data': 'kein Base64 %%%'}),
        ),
        'kaputtes Base64 in packets': (
          'write',
          schreiben(const <String, Object?>{
            'data': null,
            'packets': ['AQ==', '%%%'],
          }),
        ),
        'packets ist keine Liste': (
          'write',
          schreiben(const <String, Object?>{'data': null, 'packets': 'AQ=='}),
        ),
        'data und packets zugleich': (
          'write',
          schreiben(const <String, Object?>{
            'packets': ['AQ=='],
          }),
        ),
        'weder data noch packets': (
          'write',
          schreiben(const <String, Object?>{'data': null}),
        ),
        'withResponse fehlt': (
          'write',
          schreiben(const <String, Object?>{'withResponse': null}),
        ),
        'generation ist keine Zahl': (
          'write',
          schreiben(const <String, Object?>{'generation': 'eins'}),
        ),
        'lease ist kein Text': (
          'write',
          schreiben(const <String, Object?>{'lease': 7}),
        ),
        'Wartezeit über 30 s': (
          'lease',
          const <String, Object?>{'waitMs': 30001},
        ),
        'Wartezeit negativ': ('lease', const <String, Object?>{'waitMs': -1}),
        'Erneuern ohne lease': ('lease/renew', const <String, Object?>{}),
        'Freigeben ohne lease': ('lease/release', const <String, Object?>{}),
        'lease beim Freigeben kein Text': (
          'lease/release',
          const <String, Object?>{'lease': 7},
        ),
        'Rumpf kein JSON': ('read', '{kaputt'),
      };
      for (final MapEntry(key: fall, value: (pfad, rumpf)) in faelle.entries) {
        final response = await send(
          'POST',
          '/v1/bluetooth/devices/$fakeM110Id/$pfad',
          body: rumpf,
        );
        expect(response.status, 200, reason: fall);
        expect(response.errorCode, errorBadRequest, reason: fall);
        expect(response.error!['message'], isNotEmpty, reason: fall);
      }

      final suche = await send(
        'POST',
        '/v1/bluetooth/scan',
        body: const <String, Object?>{'durationMs': 'lang'},
      );
      expect(suche.errorCode, errorBadRequest);

      final langerName = await send(
        'PUT',
        '/v1/bluetooth/devices/$fakeM110Id',
        body: <String, Object?>{'name': 'x' * 65},
      );
      expect(langerName.errorCode, errorBadRequest);
      final keinText = await send(
        'PUT',
        '/v1/bluetooth/devices/$fakeM110Id',
        body: const <String, Object?>{'name': 5},
      );
      expect(keinText.errorCode, errorBadRequest);
      // Der Name bleibt, wie er war (ohne Suche: die Kennung).
      expect((await store.load()).bluetoothDevices.single.name, fakeM110Id);

      // Nichts davon hat das Gerät erreicht.
      expect(m110.pakete, isEmpty);
    });

    test('Schreib-Rumpf über 256 KiB: body_too_large', () async {
      await zulassen();
      final belegt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease',
        body: const <String, Object?>{},
      );
      final lease = belegt.json['lease']! as String;

      Map<String, Object?> rumpf(int fuellung) => <String, Object?>{
        'service': 'ff00',
        'characteristic': 'ff02',
        'withResponse': true,
        'lease': lease,
        'packets': <String>[],
        'pad': 'x' * fuellung,
      };

      // Ohne Socket durch dieselbe Kette (Herkunft, Token, Router): über
      // TCP verwirft der Server den ungelesenen Rest des Rumpfes, und der
      // Klient sieht je nach Zeitpunkt statt der 413 nur „Verbindung zu“.
      Future<ApiResponse> direkt(String path, Map<String, Object?> body) async {
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://127.0.0.1:${server.port}$path'),
            headers: <String, String>{
              'origin': _kasse,
              'authorization': 'Bearer $_token',
              'content-type': 'application/json',
            },
            body: utf8.encode(jsonEncode(body)),
          ),
        );
        return ApiResponse(response.statusCode, await response.readAsString());
      }

      // 200 KiB gehen durch (mehr als die üblichen 64 KB) …
      final gross = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/write',
        body: rumpf(200 * 1024),
      );
      expect(gross.ok, isTrue, reason: gross.body);
      expect(gross.json['written'], 0);

      // … über 256 KiB nicht.
      final zuGross = await direkt(
        '/v1/bluetooth/devices/$fakeM110Id/write',
        rumpf(256 * 1024),
      );
      expect(zuGross.status, 413);
      expect(zuGross.errorCode, errorBodyTooLarge);

      // Andere Bluetooth-Pfade bleiben bei 64 KB.
      final lesen = await direkt(
        '/v1/bluetooth/devices/$fakeM110Id/read',
        <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff01',
          'pad': 'x' * (64 * 1024),
        },
      );
      expect(lesen.status, 413);
      expect(lesen.errorCode, errorBodyTooLarge);
      expect(m110.pakete, isEmpty);
    });

    test('Fehler der Brücke reisen mit Code, Text und detail hinaus', () async {
      await zulassen();
      final belegt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease',
        body: const <String, Object?>{},
      );
      final lease = belegt.json['lease']! as String;

      final zuLang = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/write',
        body: <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff02',
          'withResponse': false,
          'lease': lease,
          'data': _b64(List<int>.filled(21, 0)),
        },
      );
      expect(zuLang.status, 200);
      expect(zuLang.errorCode, errorBluetoothWriteTooLong);
      expect(
        zuLang.error!['message'],
        bluetoothErrorMessages[errorBluetoothWriteTooLong],
      );
      expect(zuLang.error!['detail'], <String, Object?>{
        'written': 0,
        'packet': 0,
        'length': 21,
        'max': 20,
      });

      // Eine fremde Verbindungsnummer: nichts geht in die neue Verbindung.
      final alteNummer = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/write',
        body: <String, Object?>{
          'service': 'ff00',
          'characteristic': 'ff02',
          'withResponse': true,
          'lease': lease,
          'data': _b64(const [0x01]),
          'generation': 7,
        },
      );
      expect(alteNummer.errorCode, errorBluetoothDisconnected);
      expect(alteNummer.error!['detail'], <String, Object?>{'written': 0});

      final gesperrt = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/read',
        body: const <String, Object?>{
          'service': '1812',
          'characteristic': '2a4d',
        },
      );
      expect(gesperrt.errorCode, errorBluetoothBlocked);

      final zweite = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/lease',
        body: const <String, Object?>{'waitMs': 0},
      );
      expect(zweite.errorCode, errorBluetoothBusy);

      final trennen = await send(
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/release',
      );
      expect(trennen.errorCode, errorBluetoothBusy);
      expect(m110.pakete, isEmpty);
    });
  });

  group('Agent', () {
    late FakeM110 m110;
    late FakeBluetoothHelper fake;

    setUp(() {
      m110 = FakeM110();
      fake = FakeBluetoothHelper(log: log, geraete: [m110]);
    });

    Future<Agent> starteAgent() async {
      final agent = Agent(
        store: store,
        log: log,
        preferredPort: 0,
        openBrowser: false,
        bluetoothHelper: fake,
      );
      await agent.start();
      addTearDown(agent.stop);
      return agent;
    }

    test('Agentenstart startet keinen Helfer', () async {
      final agent = await starteAgent();
      expect(fake.starts, 0);

      final status = await _send(agent.port, 'GET', '/v1/status');
      expect(status.json['features'], ['bluetooth']);
      final bluetooth = status.json['bluetooth']! as Map<String, Object?>;
      expect(bluetooth['state'], 'unknown');
      expect(
        (await _send(
          agent.port,
          'GET',
          '/v1/status',
          withToken: false,
        )).json['features'],
        ['bluetooth'],
      );
      expect((await _send(agent.port, 'GET', '/v1/bluetooth')).ok, isTrue);
      final zugelassen = await _send(
        agent.port,
        'PUT',
        '/v1/bluetooth/devices/$fakeM110Id',
        body: const <String, Object?>{},
      );
      expect(zugelassen.ok, isTrue, reason: zugelassen.body);
      expect(fake.starts, 0, reason: 'bis hierher braucht niemand Bluetooth');

      final verbunden = await _send(
        agent.port,
        'POST',
        '/v1/bluetooth/devices/$fakeM110Id/connect',
      );
      expect(verbunden.ok, isTrue, reason: verbunden.body);
      expect(fake.starts, 1);
      expect(m110.verbunden, isTrue);

      // Mit dem Agenten endet auch das Hilfsprogramm.
      await agent.stop();
      expect(fake.laeuft, isFalse);
      expect(fake.prozesse.single.stdinGeschlossen, isTrue);
      expect(fake.state, 'unknown');
    });

    test(
      'Helfer stürzt ab: /v1/printers und /v1/status antworten weiter',
      () async {
        final agent = await starteAgent();
        await _send(
          agent.port,
          'PUT',
          '/v1/bluetooth/devices/$fakeM110Id',
          body: const <String, Object?>{},
        );
        final verbunden = await _send(
          agent.port,
          'POST',
          '/v1/bluetooth/devices/$fakeM110Id/connect',
        );
        expect(verbunden.ok, isTrue, reason: verbunden.body);

        fake.abstuerzen();
        await _warteBis(() => fake.state == helperStateRestarting);

        final zeit = Stopwatch()..start();
        final drucker = await _send(agent.port, 'GET', '/v1/printers?probe=0');
        expect(drucker.ok, isTrue, reason: drucker.body);
        expect(drucker.json['printers'], isEmpty);

        final status = await _send(agent.port, 'GET', '/v1/status');
        expect(status.ok, isTrue, reason: status.body);
        expect(status.json['features'], ['bluetooth']);
        final bluetooth = status.json['bluetooth']! as Map<String, Object?>;
        expect(bluetooth['state'], helperStateRestarting);
        final geraet = (bluetooth['devices']! as List).single as Map;
        expect(geraet['connected'], isFalse);

        final zustand = await _send(agent.port, 'GET', '/v1/bluetooth');
        expect(zustand.json['state'], helperStateRestarting);
        // Nichts davon wartet auf das Hilfsprogramm.
        expect(zeit.elapsed, lessThan(const Duration(seconds: 1)));

        // Der nächste Bluetooth-Aufruf startet es wieder.
        final wieder = await _send(
          agent.port,
          'POST',
          '/v1/bluetooth/devices/$fakeM110Id/connect',
        );
        expect(wieder.ok, isTrue, reason: wieder.body);
        expect(wieder.json['generation'], 2);
        expect(fake.starts, 2);
      },
    );
  });
}
