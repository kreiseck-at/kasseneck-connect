import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Wartet, bis [condition] zutrifft (oder die Geduld am Ende ist).
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late Agent agent;
  late String token;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-events-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    agent = Agent(store: store, log: log, preferredPort: 0, openBrowser: false);
    await agent.start();
    token = await agent.context.pairing.issueToken();
  });

  tearDown(() async {
    // Manche Tests halten den Agenten selbst an — `stop()` ist dann ein
    // No-op, das Aufräumen läuft trotzdem.
    await agent.stop();
    temp.deleteSync(recursive: true);
  });

  /// Öffnet den Ereignisstrom; der Token wandert wahlweise in die Adresse
  /// (so wie es der Browser tun muss) oder in die Kopfzeile.
  IOWebSocketChannel connect({String? queryToken, String? headerToken}) {
    final query = queryToken == null ? '' : '?token=$queryToken';
    return IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${agent.port}/v1/events$query'),
      headers: <String, Object>{
        'origin': 'https://kasse.kasseneck.at',
        if (headerToken != null) 'authorization': 'Bearer $headerToken',
      },
    );
  }

  /// Wartet auf die nächste Nachricht und dekodiert sie.
  Future<Map<String, Object?>> next(Stream<Object?> events) async {
    final raw = await events.first.timeout(const Duration(seconds: 5));
    return jsonDecode(raw! as String) as Map<String, Object?>;
  }

  /// Ruft einen Pfad ganz normal per HTTP ab (Statuscode, Rumpf, Inhaltstyp).
  Future<({int statusCode, String body, String contentType})> getRaw(
    String path,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${agent.port}$path'),
      );
      request.headers.set('origin', 'https://kasse.kasseneck.at');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return (
        statusCode: response.statusCode,
        body: body,
        contentType: '${response.headers.contentType}',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Nur der Statuscode.
  Future<int> statusOf(String path) async => (await getRaw(path)).statusCode;

  test('begrüßt mit hello samt Version und Port', () async {
    final channel = connect(queryToken: token);
    await channel.ready;
    final events = channel.stream.asBroadcastStream();

    expect(await next(events), <String, Object?>{
      'type': 'hello',
      'version': agentVersion,
      'port': agent.port,
    });

    await channel.sink.close();
  });

  test('der Token darf auch in der Kopfzeile stehen', () async {
    final channel = connect(headerToken: token);
    await channel.ready;
    final events = channel.stream.asBroadcastStream();

    expect((await next(events))['type'], 'hello');

    await channel.sink.close();
  });

  test('reicht ein print.done vom Bus weiter', () async {
    final channel = connect(queryToken: token);
    await channel.ready;
    final events = channel.stream.asBroadcastStream();
    // Erst die Begrüßung abholen, damit das Abo sicher steht.
    expect((await next(events))['type'], 'hello');

    final incoming = next(events);
    agent.events.publish(eventPrintDone, <String, Object?>{
      'printerId': 'p_abc',
      'jobId': 'beleg-1',
      'attempts': 1,
    });

    expect(await incoming, <String, Object?>{
      'type': 'print.done',
      'printerId': 'p_abc',
      'jobId': 'beleg-1',
      'attempts': 1,
    });

    await channel.sink.close();
  });

  test('reicht mehrere Ereignisse in ihrer Reihenfolge weiter', () async {
    final channel = connect(queryToken: token);
    await channel.ready;
    final events = channel.stream.asBroadcastStream();
    expect((await next(events))['type'], 'hello');

    final collected = events
        .take(2)
        .map(
          (Object? raw) => jsonDecode(raw! as String) as Map<String, Object?>,
        )
        .toList();

    agent.events.publish(eventPrinterState, <String, Object?>{
      'printerId': 'p_abc',
      'state': 'online',
    });
    agent.events.publish(eventPrintFailed, <String, Object?>{
      'printerId': 'p_abc',
      'jobId': 'beleg-2',
      'code': 'printer_offline',
    });

    final list = await collected.timeout(const Duration(seconds: 5));
    expect(list.map((e) => e['type']), <String>[
      'printer.state',
      'print.failed',
    ]);

    await channel.sink.close();
  });

  test('ohne Token kommt keine Verbindung zustande', () async {
    final channel = connect();
    await expectLater(channel.ready, throwsA(isA<WebSocketChannelException>()));
  });

  test('mit falschem Token kommt keine Verbindung zustande', () async {
    final channel = connect(queryToken: 'falsch');
    await expectLater(channel.ready, throwsA(isA<WebSocketChannelException>()));
  });

  test('fremde Herkunft kommt nicht durch', () async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${agent.port}/v1/events?token=$token'),
      headers: <String, Object>{'origin': 'https://boese.example'},
    );
    await expectLater(channel.ready, throwsA(isA<WebSocketChannelException>()));
  });

  test('nach dem Schließen ist das Abo wirklich weg', () async {
    expect(
      agent.events.hasListener,
      isFalse,
      reason: 'vor der ersten Verbindung hört niemand zu',
    );

    final channel = connect(queryToken: token);
    await channel.ready;
    final events = channel.stream.asBroadcastStream();
    expect((await next(events))['type'], 'hello');
    expect(
      agent.events.hasListener,
      isTrue,
      reason: 'die offene Verbindung ist genau ein Zuhörer',
    );

    await channel.sink.close();

    // Das Abbestellen laeuft ueber den Ereignisstrom des Sockets; dafuer
    // braucht es ein paar Runden der Ereignisschleife.
    await _waitUntil(() => !agent.events.hasListener);
    expect(
      agent.events.hasListener,
      isFalse,
      reason: 'nach dem Schließen darf kein Abo zurückbleiben',
    );

    // Und ein Ereignis in die geschlossene Verbindung bleibt folgenlos.
    agent.events.publish(eventPrintDone, <String, Object?>{'jobId': 'x'});
    expect(agent.events.hasListener, isFalse);
  });

  test('zwei Verbindungen zählen als zwei Zuhörer', () async {
    final a = connect(queryToken: token);
    await a.ready;
    expect((await next(a.stream.asBroadcastStream()))['type'], 'hello');
    final b = connect(queryToken: token);
    await b.ready;
    expect((await next(b.stream.asBroadcastStream()))['type'], 'hello');

    await a.sink.close();
    // Eine geschlossene Verbindung darf die andere nicht mitreißen.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(agent.events.hasListener, isTrue);

    await b.sink.close();
    await _waitUntil(() => !agent.events.hasListener);
    expect(agent.events.hasListener, isFalse);
  });

  test('das Anhalten schließt offene Verbindungen', () async {
    final channel = connect(queryToken: token);
    await channel.ready;
    final done = channel.stream.drain<void>();
    // Nach `stop()` gibt es keinen Context mehr, über den `agent.events`
    // liefe — den Bus deshalb vorher festhalten.
    final bus = agent.events;

    await agent.stop();

    // Der Socket haengt nach dem Upgrade nicht mehr am HttpServer — ohne das
    // Schließen des Busses bliebe er fuer immer offen.
    await done.timeout(const Duration(seconds: 5));
    expect(bus.isClosed, isTrue);
    // tearDown ruft stop() ein zweites Mal — das muss es vertragen.
  });

  test('zwei Verbindungen bekommen beide dasselbe Ereignis', () async {
    final a = connect(queryToken: token);
    final b = connect(queryToken: token);
    await a.ready;
    await b.ready;
    final ea = a.stream.asBroadcastStream();
    final eb = b.stream.asBroadcastStream();
    expect((await next(ea))['type'], 'hello');
    expect((await next(eb))['type'], 'hello');

    final first = next(ea);
    final second = next(eb);
    agent.events.publish(eventPrintDone, <String, Object?>{'jobId': 'y'});

    expect((await first)['jobId'], 'y');
    expect((await second)['jobId'], 'y');

    await a.sink.close();
    await b.sink.close();
  });

  test('ohne Token antwortet der Pfad mit 401', () async {
    expect(await statusOf('/v1/events'), 401);
  });

  test('ohne Upgrade-Kopfzeilen kommt die gewohnte Fehlerhülle', () async {
    // Die Anfrage ist an der Token-Prüfung vorbeigekommen und scheitert erst
    // am fehlenden Upgrade — und zwar als JSON, nicht als HTML-Seite von
    // shelf_web_socket.
    final response = await getRaw('/v1/events?token=$token');
    expect(response.statusCode, 426);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    expect(body['ok'], isFalse);
    final error = body['error']! as Map<String, Object?>;
    expect(error['code'], 'upgrade_required');
    expect(error['message'], 'Dieser Pfad spricht nur WebSocket.');
    expect(response.contentType, contains('application/json'));
  });

  test('der Query-Token gilt nur am Ereignispfad', () async {
    expect(await statusOf('/v1/printers?token=$token'), 401);
  });
}
