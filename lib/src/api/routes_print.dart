import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import '../printers/driver.dart';
import '../printers/queue.dart';
import 'responses.dart';

/// Obergrenze des Rumpfes beim Drucken (4 MB).
///
/// Ein Bon sind wenige Kilobyte; Platz für ein großes Logo ist trotzdem drin,
/// und mehr soll sich niemand über die lokale API abladen können.
const int printBodyLimit = 4 * 1024 * 1024;

/// Höchstlänge einer Auftrags-ID.
const int maxJobIdLength = 128;

/// `POST /v1/print` — `{printerId, jobId, bytes}`.
///
/// Der Auftrag läuft über die Warteschlange: seriell je Drucker und idempotent
/// je `jobId`. Fachfehler kommen mit HTTP 200 und `ok: false` zurück.
Future<Response> handlePrint(PrintQueue queue, Request request) async {
  final body = await readJsonBody(request, maxBytes: printBodyLimit);
  final error = body.error;
  if (error != null) return error;
  final data = body.data!;

  final printerId = _text(data['printerId']);
  if (printerId == null) {
    return failJson(errorBadRequest, 'Es fehlt die Drucker-ID (printerId).');
  }

  final jobId = _text(data['jobId']);
  if (jobId == null || jobId.length > maxJobIdLength) {
    return failJson(errorBadRequest, 'Es fehlt eine brauchbare Auftrags-ID.');
  }

  final bytes = decodePrintBytes(data['bytes']);
  if (bytes == null) {
    return failJson(
      errorBadRequest,
      'Die Druckdaten (bytes) fehlen oder sind kein Base64.',
    );
  }

  return printResponse(await queue.enqueue(printerId, jobId, bytes), jobId);
}

/// `POST /v1/printers/{id}/test` — Testseite mit den Bytes aus dem Rumpf.
///
/// Die Kasse schickt die Bytes mit: der Agent kennt weder Papierbreite noch
/// Zeichensatz des Geräts, und die Bytes sollen dieselben sein wie im Betrieb.
Future<Response> handleTestPrint(
  PrintQueue queue,
  Request request,
  String printerId,
) async {
  final body = await readJsonBody(request, maxBytes: printBodyLimit);
  final error = body.error;
  if (error != null) return error;

  final bytes = decodePrintBytes(body.data!['bytes']);
  if (bytes == null) {
    return failJson(
      errorBadRequest,
      'Die Druckdaten (bytes) fehlen oder sind kein Base64.',
    );
  }

  final jobId =
      _text(body.data!['jobId']) ??
      'test_${DateTime.now().microsecondsSinceEpoch}';
  return printResponse(await queue.enqueue(printerId, jobId, bytes), jobId);
}

/// Übersetzt das Ergebnis der Warteschlange in eine Antwort.
///
/// `detail` trägt neben der Auftrags-ID auch `mayHavePrinted: true`, wenn der
/// Bon vielleicht doch gelaufen ist — die Kasse fragt dann nach, statt blind
/// nachzudrucken.
Response printResponse(PrintResult result, String jobId) {
  if (result.ok) return okJson(<String, Object?>{'jobId': jobId});
  return failJson(
    result.code!,
    result.message!,
    detail: <String, Object?>{'jobId': jobId, ...?result.detail},
  );
}

/// Liest die base64-kodierten Druckdaten; `null`, wenn sie fehlen oder
/// unbrauchbar sind.
Uint8List? decodePrintBytes(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final bytes = base64Decode(value);
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
