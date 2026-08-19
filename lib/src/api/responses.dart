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
