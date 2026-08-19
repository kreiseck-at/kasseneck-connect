import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Verhalten des Fake-ePOS-Dienstes.
enum FakeEposMode {
  /// `<response success="true" …>`.
  success,

  /// `<response success="false" code="…" …>` — Gerät lehnt ab.
  failure,

  /// HTTP 500 statt einer ePOS-Antwort.
  serverError,

  /// Antwortet erst nach [FakeEposServer.delay].
  slow,
}

/// Fake eines Epson-ePOS-Print-Dienstes (`/cgi-bin/epos/service.cgi`).
class FakeEposServer {
  FakeEposServer._(this._server, this.mode, this.delay, this.code, this.status);

  static Future<FakeEposServer> start({
    FakeEposMode mode = FakeEposMode.success,
    Duration delay = const Duration(seconds: 1),
    String code = 'EPTR_REC_EMPTY',
    String status = '251658262',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeEposServer._(server, mode, delay, code, status);
    fake._subscription = server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final FakeEposMode mode;
  final Duration delay;
  final String code;
  final String status;

  final List<Uri> requests = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  final List<String> bodies = <String>[];

  StreamSubscription<HttpRequest>? _subscription;

  int get port => _server.port;

  /// Die zuletzt empfangenen ESC/POS-Bytes (aus `<command>` dekodiert).
  Uint8List? get lastCommand {
    if (bodies.isEmpty) return null;
    final match = RegExp(
      r'<command>(.*?)</command>',
      dotAll: true,
    ).firstMatch(bodies.last);
    if (match == null) return null;
    return base64Decode(match.group(1)!.trim());
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.requestedUri);
    final captured = <String, String>{};
    request.headers.forEach(
      (name, values) => captured[name] = values.join(','),
    );
    headers.add(captured);
    bodies.add(await utf8.decoder.bind(request).join());

    if (mode == FakeEposMode.slow) {
      await Future<void>.delayed(delay);
    }
    if (mode == FakeEposMode.serverError) {
      request.response.statusCode = 500;
      await request.response.close();
      return;
    }

    final success = mode != FakeEposMode.failure;
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
      ..write(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body>'
        '<response xmlns="http://www.epson-pos.com/schemas/2011/03/epos-print" '
        'success="$success" code="${success ? '' : code}" '
        'status="$status" battery="0" />'
        '</s:Body></s:Envelope>',
      );
    await request.response.close();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _server.close(force: true);
  }
}
