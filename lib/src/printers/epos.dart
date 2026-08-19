import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'driver.dart';
import 'tcp9100.dart' show defaultConnectTimeout;

/// Pfad des ePOS-Print-Dienstes auf Epson-Geräten.
const String eposServicePath = '/cgi-bin/epos/service.cgi';

/// Voreingestellte Geräte-ID (Epson vergibt sie in der Weboberfläche).
const String defaultEposDevid = 'local_printer';

/// Zeitlimit, das dem Drucker im Query-Parameter mitgegeben wird (ms).
const int eposDeviceTimeoutMs = 10000;

/// Obergrenze für eine ePOS-Anfrage, unabhängig vom Auftragslimit.
const Duration defaultEposRequestTimeout = Duration(seconds: 12);

/// Namensraum des ePOS-Print-Schemas.
const String eposNamespace =
    'http://www.epson-pos.com/schemas/2011/03/epos-print';

/// Epson ePOS-Print über HTTP(S).
///
/// Die ESC/POS-Bytes reisen base64-kodiert im `<command>`-Element — dieselben
/// Bytes wie über TCP 9100, nur anders verpackt. Selbstsignierte Zertifikate
/// werden akzeptiert: die Drucker bringen ab Werk eines mit, das keine CA
/// kennt, und die Verbindung geht ohnehin nur ins lokale Netz.
class EposPrinter implements PrinterDriver {
  EposPrinter(
    this.host, {
    this.port,
    this.https = false,
    this.devid = defaultEposDevid,
    this.connectTimeout = defaultConnectTimeout,
    this.requestTimeout = defaultEposRequestTimeout,
  });

  final String host;

  /// Port; `null` bedeutet den Standardport des Schemas (80 bzw. 443).
  final int? port;

  final bool https;

  /// Geräte-ID des Druckers am ePOS-Dienst.
  final String devid;

  final Duration connectTimeout;

  /// Obergrenze einer Anfrage; das Auftragslimit kann kürzer sein.
  final Duration requestTimeout;

  /// Klient des laufenden Versuchs — nur damit [abort] ihn wegwerfen kann.
  HttpClient? _current;

  /// Vollständige Adresse des Dienstes samt Geräte-ID und Gerätezeitlimit.
  Uri get endpoint => Uri(
    scheme: https ? 'https' : 'http',
    host: host,
    port: port,
    path: eposServicePath,
    queryParameters: <String, String>{
      'devid': devid,
      'timeout': '$eposDeviceTimeoutMs',
    },
  );

  @override
  Future<void> print(
    Uint8List bytes, {
    Duration timeout = defaultPrintTimeout,
  }) async {
    final response = await _post(_printEnvelope(bytes), timeout);

    if (response.status != 200) {
      throw PrinterFailure(
        errorPrinterOffline,
        'Der Drucker $host hat mit HTTP ${response.status} geantwortet.',
        detail: 'HTTP ${response.status}',
      );
    }

    final result = parseEposResponse(response.body);
    if (result == null) {
      throw PrinterFailure(
        errorPrinterOffline,
        'Der Drucker $host hat unverständlich geantwortet.',
      );
    }
    if (!result.success) {
      throw PrinterFailure(
        errorPrintRefused,
        'Der Drucker hat den Auftrag abgelehnt '
        '(${result.code.isEmpty ? 'ohne Code' : result.code}).',
        detail: 'code=${result.code} status=${result.status}',
      );
    }
  }

  @override
  Future<PrinterState> status({Duration timeout = defaultPrintTimeout}) async {
    try {
      final response = await _post(_statusEnvelope(), timeout);
      return response.status == 200
          ? PrinterState.online
          : PrinterState.offline;
    } on PrinterFailure {
      return PrinterState.offline;
    }
  }

  /// Schickt einen SOAP-Rumpf an den Dienst und liefert Status und Antwort.
  ///
  /// [_Sent] merkt sich, ob die Anfrage schon auf der Leitung war: solange nur
  /// verbunden (oder das Zertifikat geprüft) wird, ist sicher nichts gedruckt
  /// und ein zweiter Versuch gefahrlos.
  Future<_EposResponse> _post(String envelope, Duration timeout) async {
    final client = HttpClient()
      ..connectionTimeout = _shorter(connectTimeout, timeout)
      // Bondrucker bringen selbstsignierte Zertifikate mit; im lokalen Netz
      // ist das der Normalfall und kein Angriffsbild.
      ..badCertificateCallback = (X509Certificate _, String __, int ___) =>
          true;
    _current = client;
    final sent = _Sent();

    try {
      return await _exchange(
        client,
        envelope,
        sent,
      ).timeout(_shorter(requestTimeout, timeout));
    } on TimeoutException {
      throw PrinterFailure(
        errorPrintTimeout,
        sent.value
            ? unconfirmedPrintMessage
            : 'Der Drucker $host hat nicht rechtzeitig geantwortet.',
        mayHavePrinted: sent.value,
      );
    } on SocketException catch (e) {
      throw PrinterFailure(
        errorPrinterOffline,
        sent.value
            ? unconfirmedPrintMessage
            : 'Der Drucker $host ist nicht erreichbar.',
        detail: e.message,
        mayHavePrinted: sent.value,
      );
    } on HandshakeException catch (e) {
      throw PrinterFailure(
        errorPrinterOffline,
        'Die gesicherte Verbindung zum Drucker $host kam nicht zustande.',
        detail: e.message,
      );
    } on HttpException catch (e) {
      throw PrinterFailure(
        errorPrinterOffline,
        sent.value
            ? unconfirmedPrintMessage
            : 'Der Drucker $host hat die Verbindung abgebrochen.',
        detail: e.message,
        mayHavePrinted: sent.value,
      );
    } finally {
      client.close(force: true);
      _current = null;
    }
  }

  Future<_EposResponse> _exchange(
    HttpClient client,
    String envelope,
    _Sent sent,
  ) async {
    final request = await client.postUrl(endpoint);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/xml; charset=utf-8',
    );
    request.headers.set('SOAPAction', '""');
    request.add(utf8.encode(envelope));
    // `close()` schiebt den gepufferten Rumpf hinaus — ab hier gilt der
    // Auftrag als abgeschickt.
    sent.value = true;
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return _EposResponse(response.statusCode, body);
  }

  @override
  Future<void> abort() async {
    _current?.close(force: true);
    _current = null;
  }

  static String _printEnvelope(Uint8List bytes) => _envelope(
    '<epos-print xmlns="$eposNamespace">'
    '<command>${base64Encode(bytes)}</command>'
    '</epos-print>',
  );

  static String _statusEnvelope() =>
      _envelope('<epos-print xmlns="$eposNamespace"/>');

  static String _envelope(String body) =>
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body>$body</s:Body>'
      '</s:Envelope>';

  static Duration _shorter(Duration a, Duration b) => a < b ? a : b;
}

/// Ausgewertete `<response …>`-Zeile einer ePOS-Antwort.
class EposResult {
  const EposResult({
    required this.success,
    required this.code,
    required this.status,
  });

  /// `success="true"` — der Drucker hat den Auftrag angenommen.
  final bool success;

  /// Fehlercode des Geräts (z. B. `EPTR_REC_EMPTY` für „kein Papier").
  final String code;

  /// Statusbits des Geräts als Dezimalzahl.
  final String status;
}

/// Liest `<response success=".." code=".." status="..">` aus der SOAP-Antwort.
///
/// Bewusst mit einem Ausdruck statt mit einem XML-Parser: die Antwort ist
/// einzeilig und immer gleich aufgebaut, und der Agent soll ohne weitere
/// Abhängigkeit auskommen.
EposResult? parseEposResponse(String body) {
  final element = RegExp(r'<response\b([^>]*)>', dotAll: true).firstMatch(body);
  if (element == null) return null;
  final attributes = element.group(1) ?? '';

  String attribute(String name) {
    // Wortgrenze wie in der JS-Referenz: sonst läse `code` auch aus
    // `errorcode="…"`.
    final match = RegExp('\\b$name="([^"]*)"').firstMatch(attributes);
    return match?.group(1) ?? '';
  }

  return EposResult(
    success: attribute('success') == 'true',
    code: attribute('code'),
    status: attribute('status'),
  );
}

/// Veränderliches Merkzeichen „Anfrage ist raus" für [EposPrinter._post].
class _Sent {
  bool value = false;
}

class _EposResponse {
  const _EposResponse(this.status, this.body);

  final int status;
  final String body;
}
