import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:kasseneck_connect/src/api/routes_update.dart';
import 'package:kasseneck_connect/src/update/feed.dart';
import 'package:kasseneck_connect/src/update/updater.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

void main() {
  const kasse = 'https://kasse.kasseneck.at';
  late Directory temp;
  late ConfigStore store;
  late AgentContext ctx;
  late HttpServer server;
  late Completer<void> hold;
  final paket = utf8.encode('xar! Paket');
  final now = DateTime.utc(2026, 11, 2, 6);

  ConnectUpdater updater({String os = 'macos'}) => ConnectUpdater(
    feed: UpdateFeed(
      fetch: (uri, timeout) async => jsonEncode(<String, Object?>{
        'version': '1.4.1',
        'files': <String, Object?>{
          'darwin-arm64': <String, Object?>{
            'url':
                'https://github.com/kreiseck-at/kasseneck-connect/releases/download/v1.4.1/KasseneckConnect-macos-arm64.pkg',
            'sha256': sha256.convert(paket).toString(),
            'size': paket.length,
          },
        },
      }),
      clock: () => now,
    ),
    download: (url, target, onProgress) async {
      await hold.future;
      await target.writeAsBytes(paket);
    },
    run: FakeProcessRunner(defaultExitCode: 1).runner,
    events: ctx.events,
    cacheDir: Directory(p.join(temp.path, 'updates')),
    platformKey: 'darwin-arm64',
    current: '1.4.0',
    operatingSystem: os,
    clock: () => now,
  );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-update-api-');
    store = ConfigStore.forDirectory(temp);
    final log = AgentLog(Directory(p.join(temp.path, 'logs')));
    hold = Completer<void>();
    ctx = AgentContext(
      store: store,
      log: log,
      startedAt: now,
      clock: () => now,
      environment: const <String, String>{},
      pairing: Pairing(
        store: store,
        log: log,
        clock: () => now,
        random: Random(3),
        runProcess: FakeProcessRunner().runner,
      ),
    );
    server = await shelf_io.serve(
      buildHandler(ctx, extraRoutes: <RouteRegistrar>[updateRoutes()]),
      InternetAddress.loopbackIPv4,
      0,
    );
    ctx.port = server.port;
  });

  tearDown(() async {
    if (!hold.isCompleted) hold.complete();
    await ctx.updater?.running;
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  Future<(int, Map<String, Object?>)> send(
    String method,
    String path, {
    String? origin = kasse,
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (origin != null) request.headers.set('origin', origin);
      if (token != null) request.headers.set('authorization', 'Bearer $token');
      if (method == 'POST') {
        request.headers.contentType = ContentType.json;
        request.write('{}');
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (response.statusCode, jsonDecode(text) as Map<String, Object?>);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> pair() async {
    final code = await ctx.pairing.newCode();
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/pair'),
      );
      request.headers.set('origin', kasse);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(<String, Object?>{'code': code}));
      final response = await request.close();
      final json =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      return json['token'] as String;
    } finally {
      client.close(force: true);
    }
  }

  test('ohne Token 401, fremde Herkunft 403', () async {
    ctx.updater = updater();
    expect((await send('GET', '/v1/update')).$1, 401);
    final token = await pair();
    expect(
      (await send(
        'GET',
        '/v1/update',
        origin: 'https://boese.example',
        token: token,
      )).$1,
      403,
    );
  });

  test('GET liefert den Stand', () async {
    ctx.updater = updater();
    final token = await pair();
    final (status, json) = await send('GET', '/v1/update', token: token);
    expect(status, 200);
    expect(json, <String, Object?>{
      'ok': true,
      'current': '1.4.0',
      'latest': '1.4.1',
      'available': true,
      'platform': 'darwin-arm64',
      'size': paket.length,
      'oneClick': true,
    });
  });

  test(
    'POST startet und antwortet sofort; zweiter POST ist update_busy',
    () async {
      ctx.updater = updater();
      final token = await pair();
      final (status, json) = await send('POST', '/v1/update', token: token);
      expect(status, 200);
      expect(json, <String, Object?>{'ok': true, 'started': true});
      final (status2, json2) = await send('POST', '/v1/update', token: token);
      expect(status2, 409);
      expect((json2['error'] as Map)['code'], 'update_busy');
    },
  );

  test('ohne Ein-Klick: POST ist update_unsupported', () async {
    ctx.updater = updater(os: 'windows');
    final token = await pair();
    final (status, json) = await send('POST', '/v1/update', token: token);
    expect(status, 409);
    expect((json['error'] as Map)['code'], 'update_unsupported');
  });

  test('features nennt update nur mit Aktualisierer', () async {
    final ohne = await send('GET', '/v1/status');
    expect(ohne.$2['features'], isNot(contains('update')));
    ctx.updater = updater(os: 'windows');
    final mit = await send('GET', '/v1/status');
    expect(mit.$2['features'], contains('update'));
  });

  test('ohne Aktualisierer gibt es den Pfad nicht', () async {
    final token = await pair();
    expect((await send('GET', '/v1/update', token: token)).$1, 404);
  });
}
