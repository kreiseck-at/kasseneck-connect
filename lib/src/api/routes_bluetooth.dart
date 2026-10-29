/// Die Bluetooth-Endpunkte der lokalen API (`/v1/bluetooth…`).
///
/// Dünn über der [BluetoothBridge]: Eingaben prüfen und Fehler in die Hülle
/// `{ok: false, error: {code, message, detail}}` übersetzen. Fachliche Fehler
/// kommen wie überall mit HTTP 200, nur ein zu großer Rumpf mit 413.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../bluetooth/bridge.dart';
import '../bluetooth/helper.dart';
import '../bluetooth/uuids.dart';
import 'context.dart';
import 'responses.dart';

/// Obergrenze des Rumpfes beim Schreiben (256 KiB).
///
/// Ein Etikett sind einige Kilobyte Rasterdaten, Base64 legt ein Drittel
/// drauf; die Grenze lässt Luft für große Etiketten, ohne dass sich jemand
/// über die lokale API Speicher abladen kann. Alle anderen Bluetooth-Pfade
/// bleiben bei [defaultJsonBodyLimit].
const int bluetoothWriteBodyLimit = 256 * 1024;

/// Längster Name, den die Kasse einem Gerät geben darf.
const int maxBluetoothDeviceNameLength = 64;

/// Längste Wartezeit auf eine Belegung (`waitMs`).
const int maxBluetoothLeaseWaitMs = 30000;

/// Meldet die Bluetooth-Endpunkte am Router an.
///
/// Alle Pfade sind token- und herkunftsgeschützt. Eine Kennung im Pfad muss
/// [isValidDeviceId] erfüllen, sonst `bad_request`, bevor irgendetwas
/// Bluetooth oder die Konfiguration berührt. Ohne Hilfsprogramm
/// ([BluetoothBridge.available] falsch) antworten die Zugriffe
/// `bluetooth_unsupported`; `GET /v1/bluetooth` meldet dann den Zustand
/// `unsupported`, und Vergessen geht weiter (Aufräumen einer übernommenen
/// Konfiguration).
RouteRegistrar bluetoothRoutes({required BluetoothBridge bridge}) {
  return (Router router, AgentContext ctx) {
    const device = '/v1/bluetooth/devices/<id>';
    router
      ..get(
        '/v1/bluetooth',
        (Request r) => _guard(() async => okJson(await bridge.summary())),
      )
      ..post('/v1/bluetooth/scan', (Request r) => _handleScan(bridge, r))
      ..put(device, (Request r, String id) => _handleApprove(bridge, r, id))
      ..delete(
        device,
        (Request r, String id) =>
            _onDevice(bridge, id, needsBluetooth: false, (key) async {
              if (!await bridge.forget(key)) {
                return _bridgeFailure(errorBluetoothDeviceUnknown);
              }
              return okJson(<String, Object?>{'id': key});
            }),
      )
      ..post(
        '$device/connect',
        (Request r, String id) => _onDevice(
          bridge,
          id,
          (key) async => okJson(<String, Object?>{
            'connected': true,
            'generation': await bridge.connect(key),
          }),
        ),
      )
      ..post(
        '$device/release',
        (Request r, String id) => _onDevice(bridge, id, (key) async {
          await bridge.release(key);
          return okJson(const <String, Object?>{});
        }),
      )
      ..get(
        '$device/gatt',
        (Request r, String id) => _onDevice(
          bridge,
          id,
          (key) async =>
              okJson(<String, Object?>{'services': await bridge.gatt(key)}),
        ),
      )
      ..post(
        '$device/read',
        (Request r, String id) => _onDevice(bridge, id, (key) async {
          final target = await _readTarget(r);
          if (target.error case final error?) return error;
          final data = await bridge.read(
            key,
            target.service!,
            target.characteristic!,
          );
          return okJson(<String, Object?>{'data': base64Encode(data)});
        }),
      )
      ..post(
        '$device/write',
        (Request r, String id) =>
            _onDevice(bridge, id, (key) => _handleWrite(bridge, r, key)),
      )
      ..post(
        '$device/subscribe',
        (Request r, String id) => _onDevice(bridge, id, (key) async {
          final target = await _readTarget(r);
          if (target.error case final error?) return error;
          await bridge.subscribe(key, target.service!, target.characteristic!);
          return okJson(const <String, Object?>{});
        }),
      )
      ..post(
        '$device/unsubscribe',
        (Request r, String id) => _onDevice(bridge, id, (key) async {
          final target = await _readTarget(r);
          if (target.error case final error?) return error;
          await bridge.unsubscribe(
            key,
            target.service!,
            target.characteristic!,
          );
          return okJson(const <String, Object?>{});
        }),
      )
      ..get(
        '$device/notifications',
        // Verbindungsnummer und Meldungen aus demselben Augenblick: so sieht
        // die Kasse, ob der Puffer zu der Verbindung gehört, in die sie
        // geschrieben hat.
        (Request r, String id) => _onDevice(
          bridge,
          id,
          approved: true,
          (key) => okJson(<String, Object?>{
            'generation': bridge.generationOf(key),
            'notifications': <Map<String, Object?>>[
              for (final entry in bridge.notifications(key)) entry.toJson(),
            ],
          }),
        ),
      )
      ..post(
        '$device/lease',
        (Request r, String id) =>
            _onDevice(bridge, id, (key) => _handleAcquire(bridge, r, key)),
      )
      ..post(
        '$device/lease/renew',
        (Request r, String id) =>
            _onDevice(bridge, id, approved: true, (key) async {
              final lease = await _readLease(r);
              if (lease.error case final error?) return error;
              if (!bridge.renewLease(key, lease.id!)) {
                return _bridgeFailure(errorBluetoothLeaseRequired);
              }
              return okJson(const <String, Object?>{});
            }),
      )
      ..post(
        '$device/lease/release',
        // Wiederholbar und ohne Zulassungsprüfung: eine Freigabe nach Ablauf,
        // Entzug, doppeltem Senden oder nach dem Vergessen ist kein Fehler,
        // nur `released: false`.
        (Request r, String id) => _onDevice(bridge, id, (key) async {
          final lease = await _readLease(r);
          if (lease.error case final error?) return error;
          return okJson(<String, Object?>{
            'released': bridge.releaseLease(key, lease.id!),
          });
        }),
      );
  };
}

/// Ohne Brücke: jeder Bluetooth-Pfad antwortet `bluetooth_unsupported` statt
/// `not_found` – die Kasse liest daraus dasselbe wie aus `features` ohne
/// `bluetooth`.
RouteRegistrar bluetoothUnsupportedRoutes() {
  return (Router router, AgentContext ctx) {
    router
      ..all('/v1/bluetooth', (Request r) => _unsupported())
      ..all('/v1/bluetooth/<rest|.*>', (Request r, String rest) {
        return _unsupported();
      });
  };
}

// -----------------------------------------------------------------------------
// Handler

/// `POST /v1/bluetooth/scan` — `{durationMs?}`; die Brücke hält die Dauer in
/// 1–10 s.
Future<Response> _handleScan(BluetoothBridge bridge, Request request) async {
  if (!bridge.available) return _unsupported();
  final body = await readJsonBody(request, allowEmpty: true);
  if (body.error case final error?) return error;

  final raw = body.data!['durationMs'];
  if (raw != null && (raw is! int || raw < 0)) {
    return failJson(
      errorBadRequest,
      'Die Suchdauer (durationMs) muss eine ganze Zahl ab 0 sein.',
    );
  }
  return _guard(() async {
    final devices = raw is int
        ? await bridge.scan(duration: Duration(milliseconds: raw))
        : await bridge.scan();
    return okJson(<String, Object?>{'devices': devices});
  });
}

/// `PUT /v1/bluetooth/devices/{id}` — `{name?}`.
Future<Response> _handleApprove(
  BluetoothBridge bridge,
  Request request,
  String id,
) => _onDevice(bridge, id, (key) async {
  final body = await readJsonBody(request, allowEmpty: true);
  if (body.error case final error?) return error;

  final name = body.data!['name'];
  if (name != null && name is! String) {
    return failJson(errorBadRequest, 'Der Name (name) muss ein Text sein.');
  }
  if (name is String && name.trim().length > maxBluetoothDeviceNameLength) {
    return failJson(
      errorBadRequest,
      'Der Name ist zu lang (höchstens $maxBluetoothDeviceNameLength '
      'Zeichen).',
    );
  }
  final device = await bridge.approve(key, name: name as String?);
  return okJson(<String, Object?>{'device': device});
});

/// `POST /v1/bluetooth/devices/{id}/write` —
/// `{service, characteristic, withResponse, lease, data | packets[], generation?}`.
///
/// `data` ist ein Paket, `packets` mehrere; jedes geht als eigener
/// Schreibvorgang hinaus. Mit `generation` schreibt die Brücke nur in diese
/// Verbindung.
Future<Response> _handleWrite(
  BluetoothBridge bridge,
  Request request,
  String key,
) async {
  final body = await readJsonBody(request, maxBytes: bluetoothWriteBodyLimit);
  if (body.error case final error?) return error;
  final data = body.data!;

  final target = _target(data);
  if (target.error case final error?) return error;

  final withResponse = data['withResponse'];
  if (withResponse is! bool) {
    return failJson(
      errorBadRequest,
      'Es fehlt die Schreibart (withResponse: true oder false).',
    );
  }

  // Ohne Belegung entscheidet die Brücke (`bluetooth_lease_required`); nur
  // ein Wert, der gar kein Text ist, ist eine kaputte Anfrage.
  final lease = data['lease'];
  if (lease != null && lease is! String) {
    return failJson(
      errorBadRequest,
      'Die Belegung (lease) muss ein Text sein.',
    );
  }

  final generation = data['generation'];
  if (generation != null && generation is! int) {
    return failJson(
      errorBadRequest,
      'Die Verbindungsnummer (generation) muss eine ganze Zahl sein.',
    );
  }

  final packets = _packets(data);
  if (packets.error case final error?) return error;

  final written = await bridge.write(
    key,
    target.service!,
    target.characteristic!,
    packets.packets!,
    withResponse: withResponse,
    lease: lease as String? ?? '',
    generation: generation as int?,
  );
  return okJson(<String, Object?>{'written': written});
}

/// `POST /v1/bluetooth/devices/{id}/lease` — `{waitMs?}` (höchstens 30 s).
Future<Response> _handleAcquire(
  BluetoothBridge bridge,
  Request request,
  String key,
) async {
  final body = await readJsonBody(request, allowEmpty: true);
  if (body.error case final error?) return error;

  final raw = body.data!['waitMs'];
  if (raw != null &&
      (raw is! int || raw < 0 || raw > maxBluetoothLeaseWaitMs)) {
    return failJson(
      errorBadRequest,
      'Die Wartezeit (waitMs) muss zwischen 0 und $maxBluetoothLeaseWaitMs '
      'liegen.',
    );
  }
  final lease = raw is int
      ? await bridge.acquireLease(key, wait: Duration(milliseconds: raw))
      : await bridge.acquireLease(key);
  return okJson(<String, Object?>{
    'lease': lease.id,
    'ttlMs': bridge.leaseTtl.inMilliseconds,
  });
}

// -----------------------------------------------------------------------------
// Hilfen

/// Prüft die Kennung (und ob es Bluetooth gibt), führt [action] aus und
/// übersetzt Fehler der Brücke.
///
/// [approved]: die Route prüft die Zulassung selbst, weil die Brücke es für
/// diesen Zugriff nicht tut (Meldungen, Erneuern).
Future<Response> _onDevice(
  BluetoothBridge bridge,
  String id,
  FutureOr<Response> Function(String key) action, {
  bool approved = false,
  bool needsBluetooth = true,
}) async {
  if (!isValidDeviceId(id)) {
    return failJson(
      errorBadRequest,
      'Die Gerätekennung im Pfad ist unbrauchbar.',
    );
  }
  if (needsBluetooth && !bridge.available) return _unsupported();
  final key = id.toLowerCase();
  return _guard(() async {
    if (approved && !await bridge.isApproved(key)) {
      return _bridgeFailure(errorBluetoothDeviceUnknown);
    }
    return action(key);
  });
}

/// Übersetzt Fehler der Brücke in die Fehlerhülle.
Future<Response> _guard(FutureOr<Response> Function() action) async {
  try {
    return await action();
  } on BluetoothFailure catch (failure) {
    return failJson(failure.code, failure.message, detail: failure.detail);
  } on FormatException {
    // Kennungen und UUIDs prüfen die Routen vorher; das hier ist nur das
    // Netz darunter, falls die Brücke doch etwas aus der Anfrage verwirft.
    return failJson(
      errorBadRequest,
      'Die Anfrage enthält eine unbrauchbare Kennung.',
    );
  }
}

Response _bridgeFailure(String code) =>
    failJson(code, bluetoothErrorMessages[code]!);

Response _unsupported() => _bridgeFailure(errorBluetoothUnsupported);

/// Dienst und Merkmal aus dem Rumpf (lang und klein) oder eine fertige
/// Fehlerantwort.
typedef _Target = ({String? service, String? characteristic, Response? error});

Future<_Target> _readTarget(Request request) async {
  final body = await readJsonBody(request);
  if (body.error case final error?) {
    return (service: null, characteristic: null, error: error);
  }
  return _target(body.data!);
}

_Target _target(Map<String, Object?> data) {
  final service = _uuid(data['service']);
  if (service == null) {
    return (
      service: null,
      characteristic: null,
      error: failJson(
        errorBadRequest,
        'Der Dienst (service) fehlt oder ist keine gültige UUID.',
      ),
    );
  }
  final characteristic = _uuid(data['characteristic']);
  if (characteristic == null) {
    return (
      service: null,
      characteristic: null,
      error: failJson(
        errorBadRequest,
        'Das Merkmal (characteristic) fehlt oder ist keine gültige UUID.',
      ),
    );
  }
  return (service: service, characteristic: characteristic, error: null);
}

String? _uuid(Object? value) {
  if (value is! String) return null;
  try {
    return canonicalUuid(value);
  } on FormatException {
    return null;
  }
}

/// Die Pakete aus `data` oder `packets` (genau eines von beiden).
({List<Uint8List>? packets, Response? error}) _packets(
  Map<String, Object?> data,
) {
  ({List<Uint8List>? packets, Response? error}) bad(String message) =>
      (packets: null, error: failJson(errorBadRequest, message));

  final single = data['data'];
  final many = data['packets'];
  if ((single == null) == (many == null)) {
    return bad('Bitte genau eines angeben: data (ein Paket) oder packets.');
  }
  if (single != null) {
    final bytes = _base64(single);
    if (bytes == null) return bad('Die Daten (data) sind kein Base64.');
    return (packets: <Uint8List>[bytes], error: null);
  }
  if (many is! List) {
    return bad('packets muss eine Liste von Base64-Texten sein.');
  }
  final packets = <Uint8List>[];
  for (var i = 0; i < many.length; i++) {
    final bytes = _base64(many[i]);
    if (bytes == null) return bad('Paket ${i + 1} in packets ist kein Base64.');
    packets.add(bytes);
  }
  return (packets: packets, error: null);
}

Uint8List? _base64(Object? value) {
  if (value is! String) return null;
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

/// Die Belegung aus dem Rumpf (`{lease}`) oder eine fertige Fehlerantwort.
Future<({String? id, Response? error})> _readLease(Request request) async {
  final body = await readJsonBody(request);
  if (body.error case final error?) return (id: null, error: error);
  final lease = body.data!['lease'];
  if (lease is! String || lease.isEmpty) {
    return (
      id: null,
      error: failJson(errorBadRequest, 'Es fehlt die Belegung (lease).'),
    );
  }
  return (id: lease, error: null);
}
