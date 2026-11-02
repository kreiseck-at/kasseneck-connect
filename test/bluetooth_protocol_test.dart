import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/src/bluetooth/protocol.dart';
import 'package:test/test.dart';

/// Beispielzeilen aus der gemeinsamen Quelle (auch die Swift-Tests lesen sie).
Map<String, String> _beispiele() {
  final result = <String, String>{};
  for (final raw in File(
    'test/fixtures/bluetooth_protokoll_beispiele.jsonl',
  ).readAsLinesSync()) {
    if (raw.isEmpty || raw.startsWith('#')) continue;
    final tab = raw.indexOf('\t');
    result[raw.substring(0, tab)] = raw.substring(tab + 1);
  }
  return result;
}

void main() {
  final beispiele = _beispiele();

  test('Beispieldatei enthält alle Befehle und Ereignisse', () {
    final names = beispiele.keys.toSet();
    for (final op in [
      'ping',
      'state',
      'scan',
      'stopScan',
      'connect',
      'disconnect',
      'gatt',
      'read',
      'write',
      'subscribe',
      'unsubscribe',
    ]) {
      expect(names, contains('request.$op'));
    }
    for (final e in [
      'state',
      'discovered',
      'connected',
      'disconnected',
      'notification',
    ]) {
      expect(names, contains('event.$e'));
    }
  });

  group('gültige Beispielzeilen', () {
    for (final entry in beispiele.entries.where(
      (e) => !e.key.startsWith('invalid.'),
    )) {
      test(
        '${entry.key}: lesen und wieder schreiben ergibt dieselbe Zeile',
        () {
          final msg = decodeHelperLine(entry.value);
          expect(msg, isNotNull);
          expect(msg!.encode(), entry.value);
          expect(decodeHelperLine(msg.encode()), msg);
        },
      );
    }
  });

  group('ungültige Zeilen', () {
    for (final entry in beispiele.entries.where(
      (e) => e.key.startsWith('invalid.'),
    )) {
      test('${entry.key} ergibt null', () {
        expect(decodeHelperLine(entry.value), isNull);
      });
    }

    test('weitere Unsinnszeilen werfen nie', () {
      for (final l in [
        'null',
        '42',
        '"x"',
        '{"id":"1","op":"ping"}',
        '{"id":1,"ok":false}',
        '{"id":1,"ok":false,"error":"x"}',
        '{"id":1,"op":"ping","args":[]}',
        '{"event":5}',
        '\u0000',
      ]) {
        expect(decodeHelperLine(l), isNull, reason: l);
      }
    });
  });

  test('Anfrage, Antwort und Ereignis haben die erwarteten Typen', () {
    final req = decodeHelperLine(beispiele['request.write']!);
    expect(req, isA<HelperRequest>());
    final r = req as HelperRequest;
    expect(r.id, 9);
    expect(r.op, 'write');
    expect(r.args['withResponse'], false);

    final ok =
        decodeHelperLine(beispiele['response.okRead']!)! as HelperResponse;
    expect(ok.ok, isTrue);
    expect(ok.data['data'], 'AgK2AA==');

    final err =
        decodeHelperLine(beispiele['response.error']!)! as HelperResponse;
    expect(err.ok, isFalse);
    expect(
      err.error,
      const HelperError('not_connected', 'peripheral is not connected'),
    );

    final ev = decodeHelperLine(beispiele['event.connected']!)! as HelperEvent;
    expect(ev.event, 'connected');
    expect(ev.data['maxWriteWithoutResponse'], 20);
    expect(ev.data.containsKey('event'), isFalse);
  });

  test('unbekannte Zusatzfelder werden ignoriert', () {
    final req = decodeHelperLine('{"id":1,"op":"ping","args":{},"neu":true}');
    expect(req, const HelperRequest(1, 'ping'));
    final res = decodeHelperLine('{"id":2,"ok":true,"result":{},"x":1}');
    expect(res, const HelperResponse(2, {}));
    final err = decodeHelperLine(
      '{"id":3,"ok":false,"error":{"code":"bad_request","message":"m","x":1},"y":2}',
    );
    expect(
      err,
      const HelperResponse(3, {}, error: HelperError('bad_request', 'm')),
    );
  });

  test(
    'Anfrage ohne args gilt als leere args; Zeile mit Leerraum und Zeilenende',
    () {
      expect(
        decodeHelperLine('{"id":1,"op":"ping"}\r\n'),
        const HelperRequest(1, 'ping'),
      );
    },
  );

  test('encode erzeugt genau eine Zeile', () {
    final line = HelperRequest(1, 'write', {'data': 'a\nb'}).encode();
    expect(line.contains('\n'), isFalse);
    expect(jsonDecode(line), isA<Map<String, dynamic>>());
  });
}
