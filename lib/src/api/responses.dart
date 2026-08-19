import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Fremde Herkunft (Origin) — 403.
const String errorOriginForbidden = 'origin_forbidden';

/// Token fehlt oder passt nicht — 401.
const String errorUnauthorized = 'unauthorized';

/// Pfad gibt es nicht — 404.
const String errorNotFound = 'not_found';

/// Rumpf oder Parameter unbrauchbar.
const String errorBadRequest = 'bad_request';

/// Rumpf größer als erlaubt — 413.
const String errorBodyTooLarge = 'body_too_large';

/// Der Pfad spricht nur WebSocket, die Anfrage war eine gewöhnliche (HTTP 426).
const String errorUpgradeRequired = 'upgrade_required';

/// Voreingestellte Obergrenze für JSON-Rümpfe (64 KB).
///
/// `POST /v1/print` bekommt in A3 eine eigene, größere Grenze — die Beleg-Bytes
/// kommen base64-kodiert im Rumpf.
const int defaultJsonBodyLimit = 64 * 1024;

/// Kopplungscode falsch oder verbraucht.
const String errorPairInvalid = 'pair_invalid';

/// Kopplungscode abgelaufen.
const String errorPairExpired = 'pair_expired';

/// Zu viele Fehlversuche — kurz gesperrt.
const String errorPairLocked = 'pair_locked';

/// Erfolgsantwort `{ok: true, ...}`.
///
/// Fachliche Antworten sind immer HTTP 200; nur Transportfehler (Herkunft,
/// Token, unbekannter Pfad) tragen einen anderen Status.
Response okJson(Map<String, Object?> data, {Map<String, Object>? headers}) {
  return _json(200, <String, Object?>{'ok': true, ...data}, headers);
}

/// Fehlerantwort `{ok: false, error: {code, message, detail?}}`.
///
/// [message] ist deutscher Klartext — die Kasse zeigt ihn unverändert an.
Response failJson(
  String code,
  String message, {
  int status = 200,
  Object? detail,
  Map<String, Object>? headers,
}) {
  return _json(status, <String, Object?>{
    'ok': false,
    'error': <String, Object?>{
      'code': code,
      'message': message,
      if (detail != null) 'detail': detail,
    },
  }, headers);
}

/// Ergebnis von [readJsonBody]: entweder [data] oder eine fertige [error].
class JsonBody {
  const JsonBody._(this.data, this.error);

  /// Der gelesene Rumpf (`null`, wenn [error] gesetzt ist).
  final Map<String, Object?>? data;

  /// Fertige Fehlerantwort für den Aufrufer.
  final Response? error;
}

/// Liest einen JSON-Rumpf mit Obergrenze.
///
/// Die Grenze wird beim Lesen geprüft, nicht danach: ein Angreifer auf der
/// Loopback-Schnittstelle soll den Agenten nicht mit einem endlosen Rumpf
/// vollaufen lassen können.
/// [allowEmpty] lässt einen leeren Rumpf als `{}` durchgehen — für Endpunkte,
/// deren Angaben allesamt freiwillig sind (`POST /v1/printers/discover`).
Future<JsonBody> readJsonBody(
  Request request, {
  int maxBytes = defaultJsonBodyLimit,
  bool allowEmpty = false,
}) async {
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) {
      return JsonBody._(
        null,
        failJson(
          errorBodyTooLarge,
          'Der Rumpf ist zu groß (höchstens ${maxBytes ~/ 1024} KB).',
          status: 413,
        ),
      );
    }
  }

  try {
    final raw = utf8.decode(bytes);
    if (allowEmpty && raw.trim().isEmpty) {
      return const JsonBody._(<String, Object?>{}, null);
    }
    final decoded = jsonDecode(raw) as Object?;
    if (decoded is! Map) {
      return JsonBody._(
        null,
        failJson(errorBadRequest, 'Erwartet wird ein JSON-Objekt.'),
      );
    }
    return JsonBody._(
      decoded.map((key, dynamic value) => MapEntry('$key', value as Object?)),
      null,
    );
  } on FormatException {
    return JsonBody._(
      null,
      failJson(errorBadRequest, 'Der Rumpf ist kein gültiges JSON.'),
    );
  }
}

Response _json(
  int status,
  Map<String, Object?> body,
  Map<String, Object>? headers,
) {
  return Response(
    status,
    body: jsonEncode(body),
    headers: <String, Object>{
      'content-type': 'application/json; charset=utf-8',
      ...?headers,
    },
  );
}
