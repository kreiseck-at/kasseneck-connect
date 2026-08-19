import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  /// Ruft einen Pfad ganz normal per HTTP ab und liefert den Statuscode.
  Future<int> statusOf(String path) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${agent.port}$path'),
      );
      request.headers.set('origin', 'https://kasse.kasseneck.at');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

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

  test('nach dem Schließen ist das Abo weg', () async {
    final channel = connect(queryToken: token);
    await channel.ready;
    final events = channel.stream.asBroadcastStream();
    expect((await next(events))['type'], 'hello');
    await channel.sink.close();

    // Der Bus darf nach dem Schließen ohne Zuhörer weiterlaufen; ein Ereignis
    // in die tote Verbindung darf den Agenten nicht umbringen.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    agent.events.publish(eventPrintDone, <String, Object?>{'jobId': 'x'});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Der Agent lebt: eine zweite Verbindung wird weiterhin begrüßt.
    final second = connect(queryToken: token);
    await second.ready;
    expect((await next(second.stream.asBroadcastStream()))['type'], 'hello');
    await second.sink.close();
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

  test(
    'mit gültigem Token kommt die Anfrage bis zum WebSocket-Handler',
    () async {
      // Ohne Upgrade-Kopfzeilen lehnt der WebSocket-Handler selbst ab (404) —
      // die Anfrage ist also an der Token-Prüfung vorbeigekommen.
      expect(await statusOf('/v1/events?token=$token'), 404);
    },
  );

  test('der Query-Token gilt nur am Ereignispfad', () async {
    expect(await statusOf('/v1/printers?token=$token'), 401);
  });
}
