/// Nachrichtenprotokoll zwischen Agent und Bluetooth-Hilfsprogramm.
///
/// Eine Zeile ist ein JSON-Objekt (siehe `docs/bluetooth-protokoll.md`).
/// Rein und ohne `dart:io`, damit es ohne Hilfsprogramm testbar bleibt.
library;

import 'dart:convert';

/// Befehle, die der Agent an das Hilfsprogramm schickt.
abstract final class HelperOp {
  static const ping = 'ping';
  static const state = 'state';
  static const scan = 'scan';
  static const stopScan = 'stopScan';
  static const connect = 'connect';
  static const disconnect = 'disconnect';
  static const gatt = 'gatt';
  static const read = 'read';
  static const write = 'write';
  static const subscribe = 'subscribe';
  static const unsubscribe = 'unsubscribe';
}

/// Ereignisse, die das Hilfsprogramm ungefragt meldet.
abstract final class HelperEventName {
  static const state = 'state';
  static const discovered = 'discovered';
  static const connected = 'connected';
  static const disconnected = 'disconnected';
  static const notification = 'notification';
}

/// Zustandsnamen des Funkmoduls, wie CoreBluetooth sie benennt.
const List<String> helperStates = [
  'unknown',
  'resetting',
  'unsupported',
  'unauthorized',
  'poweredOff',
  'poweredOn',
];

/// Fehlercodes des Hilfsprogramms.
abstract final class HelperErrorCode {
  static const unknownDevice = 'unknown_device';
  static const notConnected = 'not_connected';
  static const unknownCharacteristic = 'unknown_characteristic';
  static const unsupportedOperation = 'unsupported_operation';
  static const writeFailed = 'write_failed';
  static const readFailed = 'read_failed';
  static const bluetoothOff = 'bluetooth_off';
  static const unauthorized = 'unauthorized';
  static const bluetoothUnsupported = 'bluetooth_unsupported';
  static const badRequest = 'bad_request';
}

/// Fehler einer Antwort. Die Meldung ist nur fürs Protokoll gedacht.
class HelperError {
  const HelperError(this.code, this.message);

  final String code;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is HelperError && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'HelperError($code, $message)';
}

sealed class HelperMessage {
  const HelperMessage();

  Map<String, Object?> toJson();

  /// Die Nachricht als eine Zeile (ohne Zeilenende).
  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is HelperMessage &&
      other.runtimeType == runtimeType &&
      other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => '$runtimeType(${encode()})';
}

/// Befehl des Agenten; [id] ordnet die Antwort zu.
class HelperRequest extends HelperMessage {
  const HelperRequest(this.id, this.op, [this.args = const {}]);

  final int id;
  final String op;
  final Map<String, Object?> args;

  @override
  Map<String, Object?> toJson() => {'id': id, 'op': op, 'args': args};
}

/// Antwort auf einen Befehl. Der Nutzinhalt steht unter `result`, damit er
/// nicht mit dem Base64-Feld `data` von `read` zusammenstößt.
class HelperResponse extends HelperMessage {
  const HelperResponse(this.id, this.data, {this.error});

  final int id;
  final Map<String, Object?> data;
  final HelperError? error;

  bool get ok => error == null;

  @override
  Map<String, Object?> toJson() {
    final e = error;
    if (e == null) return {'id': id, 'ok': true, 'result': data};
    return {
      'id': id,
      'ok': false,
      'error': {'code': e.code, 'message': e.message},
    };
  }
}

/// Ungefragte Meldung; trägt kein `id`. [data] sind die übrigen Felder.
class HelperEvent extends HelperMessage {
  const HelperEvent(this.event, [this.data = const {}]);

  final String event;
  final Map<String, Object?> data;

  @override
  Map<String, Object?> toJson() => {'event': event, ...data};
}

Map<String, Object?>? _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;

/// Liest eine Zeile des Hilfsprogramms (oder eines Testgegenübers).
///
/// Gibt bei allem, was keine gültige Nachricht ist, `null` zurück – wirft nie.
HelperMessage? decodeHelperLine(String line) {
  try {
    final text = line.trim();
    if (text.isEmpty) return null;
    final json = _map(jsonDecode(text));
    if (json == null) return null;

    final id = json['id'];
    final event = json['event'];
    if (event is String && id == null) {
      return HelperEvent(event, Map.of(json)..remove('event'));
    }
    if (id is! int) return null;

    final op = json['op'];
    if (op is String) {
      final args = json['args'];
      if (args != null && _map(args) == null) return null;
      return HelperRequest(id, op, _map(args) ?? const {});
    }

    final ok = json['ok'];
    if (ok is! bool) return null;
    if (ok) {
      final result = json['result'];
      if (result != null && _map(result) == null) return null;
      return HelperResponse(id, _map(result) ?? const {});
    }
    final err = _map(json['error']);
    final code = err?['code'];
    if (code is! String) return null;
    final message = err?['message'];
    return HelperResponse(
      id,
      const {},
      error: HelperError(code, message is String ? message : ''),
    );
  } catch (_) {
    return null;
  }
}
