import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log/logger.dart';

/// Hobex-HPS-Terminals sprechen JSON-REST über HTTP auf diesem Port.
const int hpsDefaultPort = 8080;

/// Terminal am Netz, antwortet aber nicht wie erwartet / meldet einen Fehler.
const String errorTerminalError = 'terminal_error';

/// Terminal unter Host:Port nicht erreichbar (aus, falsche IP, anderes Netz).
const String errorTerminalOffline = 'terminal_offline';

/// Das Terminal hat nicht rechtzeitig geantwortet.
const String errorTerminalTimeout = 'timeout';

/// Kurze Aufrufe (Erreichbarkeit, Diagnose, Status, Abbruch). Die Diagnose
/// fragt beim Autorisierungs-Host nach und darf ein paar Sekunden brauchen.
const Duration hpsKurzTimeout = Duration(seconds: 15);

/// Eine Zahlung blockiert, bis der Kartenflow am Terminal fertig ist — das
/// HPS selbst rechnet mit bis zu drei Minuten (Karte, PIN, Autorisierung).
const Duration hpsZahlungTimeout = Duration(minutes: 4);

/// Fehler auf dem Weg zum Terminal — `code` für die Kasse, `message` deutsch.
class HpsWegFehler implements Exception {
  HpsWegFehler(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'HpsWegFehler($code): $message';
}

/// Dünne Brücke zum Hobex-HPS: baut die HTTP-Aufrufe, reicht die JSON-Antwort
/// unverändert durch und übersetzt nur die Transportfehler ins Deutsche.
///
/// Bewusst zustandslos: Host, Port und TID kommen mit jeder Anfrage aus der
/// Kasse (dort sind sie konfiguriert), der Agent merkt sich nichts. Eine
/// **abgelehnte** Zahlung ist KEIN Fehler dieser Brücke — das HPS antwortet
/// dann mit HTTP 200 und `responseCode != "0"`, und genau so kommt es bei der
/// Kasse an (nur sie weiß, wie sie dem Kassier eine Ablehnung zeigt).
class HpsBridge {
  HpsBridge({required this.log});

  final AgentLog log;

  /// Erkennungs-Probe ohne TID: `GET /api/terminals/0/diagnosis`.
  ///
  /// Das echte HPS (belegt an hps 1.10.0) antwortet darauf mit HTTP 200 und
  /// `{"responseCode":"100108","responseText":"Invalid TID","tid":"0"}` —
  /// keine Zahlung, keine Nebenwirkung, und die Form der Antwort verrät das
  /// Terminal. Ein `GET /api/terminals` gibt es am Terminal NICHT ("Endpoint
  /// not implemented", 404) — den Endpunkt kennt nur die Hobex-Cloud-API.
  Future<Object?> probe({required String host, required int port}) {
    return _call('GET', host, port, '/api/terminals/0/diagnosis');
  }

  /// `GET /api/terminals/{tid}/diagnosis` — Diagnose ohne Zahlung; das
  /// Terminal prüft dabei auch die Verbindung zum Autorisierungs-Host.
  Future<Object?> diagnosis({
    required String host,
    required int port,
    required String tid,
  }) {
    return _call('GET', host, port, '/api/terminals/$tid/diagnosis');
  }

  /// `POST /api/transaction/payment` — Verkauf. Blockiert bis zum Ende des
  /// Kartenflows. Beträge kommen als Cent herein und gehen als Euro-Zahl
  /// hinaus (das HPS rechnet in Haupteinheiten: `1.5` = € 1,50).
  Future<Object?> payment({
    required String host,
    required int port,
    required String tid,
    required int amountCents,
    required String transactionId,
    int? tipCents,
    String? reference,
    String currency = 'EUR',
    String? language,
  }) {
    final transaction = <String, Object?>{
      'transactionType': 1,
      'transactionId': transactionId,
      'tid': tid,
      'currency': currency,
      'amount': amountCents / 100,
      if (tipCents != null) 'tip': tipCents / 100,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
      if (language != null) 'language': language,
    };
    return _call(
      'POST',
      host,
      port,
      '/api/transaction/payment',
      body: <String, Object?>{'transaction': transaction},
      timeout: hpsZahlungTimeout,
    );
  }

  /// `GET /api/v2/transactions/{tid}/{txId}` — Stand einer Transaktion; der
  /// Rettungsweg, wenn der lange Zahlungs-Aufruf gerissen ist.
  Future<Object?> status({
    required String host,
    required int port,
    required String tid,
    required String transactionId,
  }) {
    return _call('GET', host, port, '/api/v2/transactions/$tid/$transactionId');
  }

  /// `POST /api/transaction/abort/{tid}/{txId}` — Abbruch, solange noch keine
  /// Karte durchgezogen ist.
  Future<Object?> abort({
    required String host,
    required int port,
    required String tid,
    required String transactionId,
  }) {
    return _call(
      'POST',
      host,
      port,
      '/api/transaction/abort/$tid/$transactionId',
    );
  }

  Future<Object?> _call(
    String method,
    String host,
    int port,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = hpsKurzTimeout,
  }) async {
    final client = HttpClient()..connectionTimeout = hpsKurzTimeout;
    try {
      final uri = Uri(scheme: 'http', host: host, port: port, path: path);
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        // Content-Length ausdruecklich setzen: ohne ihn schickt Dart den
        // Rumpf chunked, und der eingebettete HPS-Server antwortet darauf
        // mit Klartext statt JSON (Zahlung kam nie an — belegt am Geraet,
        // hps 1.10.0). curl/package:http setzen die Laenge immer.
        final bytes = utf8.encode(jsonEncode(body));
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      Object? daten;
      try {
        daten = text.trim().isEmpty ? null : jsonDecode(text);
      } on FormatException {
        throw HpsWegFehler(
          errorTerminalError,
          'Das Terminal antwortet, aber nicht im HPS-Format — '
          'ist unter $host:$port wirklich das Hobex-Terminal?',
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        // 400/403/404/503 tragen laut Spec ein `message`-Feld.
        final message = daten is Map ? daten['message'] : null;
        throw HpsWegFehler(
          errorTerminalError,
          message is String && message.trim().isNotEmpty
              ? 'Terminal meldet (HTTP ${response.statusCode}): ${message.trim()}'
              : 'Terminal meldet HTTP ${response.statusCode}.',
        );
      }
      return daten;
    } on HpsWegFehler {
      rethrow;
    } on TimeoutException {
      throw HpsWegFehler(
        errorTerminalTimeout,
        'Das Terminal hat nicht rechtzeitig geantwortet.',
      );
    } on SocketException catch (e) {
      log.info('HPS $host:$port nicht erreichbar: ${e.message}');
      throw HpsWegFehler(
        errorTerminalOffline,
        'Terminal unter $host:$port nicht erreichbar — eingeschaltet und im '
        'selben Netz?',
      );
    } on HttpException {
      throw HpsWegFehler(
        errorTerminalError,
        'Die Verbindung zum Terminal ist abgerissen.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// Sieht [antwort] nach einem Hobex-HPS aus? (JSON-Objekt mit `responseCode` —
/// so antwortet das Terminal auch auf die TID-lose Probe.)
bool siehtNachHpsAus(Object? antwort) =>
    antwort is Map && antwort['responseCode'] != null;
