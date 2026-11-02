// Probewerkzeug für die lokale Bluetooth-API von Kasseneck Connect.
//
//   dart run tool/bluetooth_probe.dart koppeln <code> --token-datei <pfad>
//   dart run tool/bluetooth_probe.dart --token-datei <pfad> scan
//   dart run tool/bluetooth_probe.dart --token-datei <pfad> approve <id>
//   dart run tool/bluetooth_probe.dart --token-datei <pfad> print <id> <datei.hex>
//   dart run tool/bluetooth_probe.dart --token-datei <pfad> watch <id>
//
// Gedacht für den Gerätetest am Drucker: das Werkzeug spricht nur die lokale
// API des Agenten (wie die Kasse) und zeigt Bytes ausschließlich als Hex.
// Was die Bytes bedeuten, weiß es nicht.
//
// Verbindung: HTTP-Port per `GET /v1/status` auf 27182–27189 (oder `--port`),
// danach standardmäßig HTTPS über den dort gemeldeten `httpsPort`; `--http`
// bleibt bei reinem HTTP. Der Token steht nie auf der Ausgabe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';

/// Herkunft, mit der das Werkzeug anklopft. Die lokale API lässt ohne Herkunft
/// nur Status und Kopplung zu; das Werkzeug gibt sich deshalb als die Kasse
/// aus – es läuft ohnehin nur auf demselben Rechner.
const String probeOrigin = 'https://kasse.kasseneck.at';

/// Standardgröße eines Pakets in Byte.
const int defaultPacketSize = 180;

/// Abstand, in dem die Belegung beim Senden verlängert wird.
const Duration leaseRenewInterval = Duration(seconds: 2);

/// So lange wartet das Werkzeug auf eine Belegung (Höchstwert der API).
const int leaseWaitMs = 30000;

const String _ff00 = 'ff00';
const String _ff02 = 'ff02';
const String _ff03 = 'ff03';

Future<void> main(List<String> args) async {
  final code = await runProbe(args, out: stdout, err: stderr);
  await stdout.flush();
  exit(code);
}

/// Fehler der API (`{ok: false, error: {code, message}}`) oder der Verbindung.
class ProbeError implements Exception {
  ProbeError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Falsche Bedienung des Werkzeugs (Exit-Code 64).
class ProbeUsageError implements Exception {
  ProbeUsageError(this.message);

  final String message;
}

// -----------------------------------------------------------------------------
// Reine Funktionen

/// Liest Hex-Text: nur Hex-Ziffern, Leerraum und Zeilenumbrüche werden
/// überlesen (Format der druck-kit-Goldens).
///
/// Eine ungerade Ziffernzahl oder ein fremdes Zeichen ist ein
/// [FormatException] mit Zeilennummer.
Uint8List parseHexText(String text) {
  final bytes = <int>[];
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  int? pending;
  var pendingLine = 0;
  for (var i = 0; i < lines.length; i++) {
    final lineNumber = i + 1;
    for (final unit in lines[i].codeUnits) {
      if (unit == 0x20 || unit == 0x09) continue;
      final digit = _hexDigit(unit);
      if (digit == null) {
        throw FormatException(
          'Zeile $lineNumber: unerlaubtes Zeichen '
          '"${String.fromCharCode(unit)}" (erlaubt: Hex-Ziffern und Leerraum).',
        );
      }
      if (pending == null) {
        pending = digit;
        pendingLine = lineNumber;
      } else {
        bytes.add(pending << 4 | digit);
        pending = null;
      }
    }
  }
  if (pending != null) {
    throw FormatException(
      'Zeile $pendingLine: ungerade Anzahl Hex-Ziffern '
      '(das letzte Byte ist unvollständig).',
    );
  }
  return Uint8List.fromList(bytes);
}

int? _hexDigit(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
  if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
  return null;
}

/// Teilt [data] in Pakete zu höchstens [size] Byte (das letzte darf kürzer
/// sein). Leere Daten ergeben keine Pakete.
List<Uint8List> splitPackets(Uint8List data, int size) {
  if (size < 1) {
    throw ArgumentError.value(size, 'size', 'muss mindestens 1 sein');
  }
  return <Uint8List>[
    for (var i = 0; i < data.length; i += size)
      Uint8List.sublistView(
        data,
        i,
        i + size > data.length ? data.length : i + size,
      ),
  ];
}

/// Bytes als Hex, durch Leerzeichen getrennt (`1a 0f 0c`).
String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Die Optionen des Werkzeugs.
ArgParser buildProbeParser() => ArgParser(allowTrailingOptions: true)
  ..addOption('token', help: 'Token der Kopplung (besser: --token-datei).')
  ..addOption('token-datei', help: 'Datei mit dem Token.')
  ..addOption('port', help: 'HTTP-Port des Agenten (sonst 27182–27189).')
  ..addFlag('http', negatable: false, help: 'Reines HTTP statt HTTPS.')
  ..addOption('paket', defaultsTo: '$defaultPacketSize', help: 'Paketgröße.')
  ..addFlag('ohne-antwort', negatable: false, help: 'Ohne Antwort schreiben.')
  ..addOption(
    'warten',
    defaultsTo: '5',
    help: 'Sekunden Warten nach dem Senden.',
  )
  ..addOption(
    'abbrechen-nach',
    help: 'Prozess nach n Paketen hart beenden (ohne Freigabe).',
  )
  ..addOption('name', help: 'Name beim Zulassen (approve).');

/// Zeitstempel- und Ausgabehilfe: jede Zeile bekommt die Millisekunden seit
/// dem Start.
class _Zeilen {
  _Zeilen(this._out, this._uhr, this._saeubern);

  final StringSink _out;
  final Stopwatch _uhr;
  final String Function(String) _saeubern;

  void zeile(String text) {
    final ms = _uhr.elapsedMilliseconds.toString().padLeft(6);
    _out.writeln('[$ms ms] ${_saeubern(text)}');
  }
}

// -----------------------------------------------------------------------------
// Lauf

/// Führt das Werkzeug aus und liefert den Exit-Code (0 ok, 1 Fehler,
/// 64 falsche Bedienung).
///
/// [hardExit] beendet den Prozess ohne jedes Aufräumen (nur für
/// `--abbrechen-nach` und Strg-C beim Senden; im Test ersetzt). [interrupt]
/// liefert Strg-C.
Future<int> runProbe(
  List<String> args, {
  required StringSink out,
  required StringSink err,
  void Function(int code)? hardExit,
  Stream<ProcessSignal>? interrupt,
}) async {
  final parser = buildProbeParser();
  late final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    err.writeln('Fehler: ${e.message}');
    return 64;
  }

  final uhr = Stopwatch()..start();
  var token = '';
  String saeubern(String text) =>
      token.isEmpty ? text : text.replaceAll(token, '***');
  final ausgabe = _Zeilen(out, uhr, saeubern);

  try {
    final rest = results.rest;
    if (rest.isEmpty || rest.first == 'help') {
      out.writeln(_usage(parser));
      return rest.isEmpty ? 64 : 0;
    }
    final befehl = rest.first;
    final params = rest.skip(1).toList();

    if (befehl == 'koppeln') {
      if (params.length != 1) {
        throw ProbeUsageError('koppeln <code> --token-datei <pfad>');
      }
      final datei = results['token-datei'] as String?;
      if (datei == null) {
        throw ProbeUsageError('koppeln braucht --token-datei.');
      }
      final verbindung = await _verbinden(results, token: null);
      try {
        final antwort = await verbindung.call(
          'POST',
          '/v1/pair',
          body: <String, Object?>{'code': params.first},
          origin: false,
          auth: false,
        );
        final neu = antwort['token'];
        if (neu is! String || neu.isEmpty) {
          throw ProbeError('pair_failed', 'Der Agent lieferte keinen Token.');
        }
        token = neu;
        _schreibeGeheim(datei, neu);
        ausgabe.zeile(
          'Gekoppelt. Token in $datei gespeichert (nur für dich lesbar).',
        );
      } finally {
        verbindung.close();
      }
      return 0;
    }

    token = _liesToken(results);
    final verbindung = await _verbinden(results, token: token);
    try {
      switch (befehl) {
        case 'scan':
          await _scan(verbindung, ausgabe);
        case 'approve':
          await _approve(
            verbindung,
            ausgabe,
            _id(params),
            results['name'] as String?,
          );
        case 'print':
          if (params.length != 2) {
            throw ProbeUsageError('print <id> <datei.hex>');
          }
          return await _print(
            verbindung,
            ausgabe,
            uhr,
            id: _id(params.take(1).toList()),
            dateiPfad: params[1],
            paket: _zahl(results['paket'] as String, 'paket', min: 1),
            mitAntwort: !(results['ohne-antwort'] as bool),
            wartenSekunden: _zahl(
              results['warten'] as String,
              'warten',
              min: 0,
            ),
            abbrechenNach: results['abbrechen-nach'] == null
                ? null
                : _zahl(
                    results['abbrechen-nach'] as String,
                    'abbrechen-nach',
                    min: 0,
                  ),
            hardExit: hardExit ?? exit,
            interrupt: interrupt ?? ProcessSignal.sigint.watch(),
          );
        case 'watch':
          await _watch(
            verbindung,
            ausgabe,
            _id(params),
            interrupt ?? ProcessSignal.sigint.watch(),
          );
        default:
          throw ProbeUsageError(
            'Unbekannter Befehl "$befehl".\n${_usage(parser)}',
          );
      }
    } finally {
      verbindung.close();
    }
    return 0;
  } on ProbeUsageError catch (e) {
    err.writeln('Fehler: ${saeubern(e.message)}');
    return 64;
  } on ProbeError catch (e) {
    err.writeln('Fehler ${e.code}: ${saeubern(e.message)}');
    return 1;
  } on FormatException catch (e) {
    err.writeln('Fehler: ${saeubern(e.message)}');
    return 1;
  } on Object catch (e) {
    err.writeln('Fehler: ${saeubern('$e')}');
    return 1;
  }
}

String _usage(ArgParser parser) =>
    'Aufruf: bluetooth_probe [Optionen] <befehl>\n'
    'Befehle: koppeln <code> | scan | approve <id> | print <id> <datei.hex> | watch <id>\n'
    '${parser.usage}';

String _id(List<String> params) {
  if (params.length != 1) {
    throw ProbeUsageError('Es fehlt genau die Gerätekennung.');
  }
  return params.first.toLowerCase();
}

int _zahl(String text, String name, {required int min}) {
  final n = int.tryParse(text);
  if (n == null || n < min) {
    throw ProbeUsageError('--$name muss eine ganze Zahl ab $min sein.');
  }
  return n;
}

String _liesToken(ArgResults results) {
  final direkt = results['token'] as String?;
  final datei = results['token-datei'] as String?;
  if (direkt != null && datei != null) {
    throw ProbeUsageError('Entweder --token oder --token-datei, nicht beides.');
  }
  if (direkt != null && direkt.trim().isNotEmpty) return direkt.trim();
  if (datei != null) {
    final file = File(datei);
    if (!file.existsSync()) {
      throw ProbeUsageError('Die Token-Datei $datei gibt es nicht.');
    }
    final inhalt = file.readAsStringSync().trim();
    if (inhalt.isEmpty) {
      throw ProbeUsageError('Die Token-Datei $datei ist leer.');
    }
    return inhalt;
  }
  throw ProbeUsageError(
    'Es fehlt --token oder --token-datei (Kopplung: koppeln).',
  );
}

/// Schreibt [inhalt] in [pfad], lesbar nur für den Benutzer. Die Datei wird
/// zuerst leer angelegt und eingeschränkt, damit der Token nie kurz offen
/// liegt.
void _schreibeGeheim(String pfad, String inhalt) {
  final file = File(pfad)..createSync(recursive: true);
  if (!Platform.isWindows) {
    final result = Process.runSync('chmod', <String>['600', pfad]);
    if (result.exitCode != 0) {
      throw ProbeError(
        'file_mode',
        'Die Rechte von $pfad ließen sich nicht setzen.',
      );
    }
  }
  file.writeAsStringSync('$inhalt\n', flush: true);
}

// -----------------------------------------------------------------------------
// Verbindung zur API

/// Eine Verbindung zum Agenten: Basisadresse, Token, Anfragen und Ereignisse.
class ProbeConnection {
  ProbeConnection(this.base, this.token) : _client = HttpClient();

  final Uri base;
  final String? token;
  final HttpClient _client;

  /// Ruft die API; liefert den Rumpf bei `ok: true`, sonst [ProbeError].
  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Object? body,
    bool origin = true,
    bool auth = true,
  }) async {
    final request = await _client
        .openUrl(method, base.replace(path: path))
        .timeout(const Duration(seconds: 10));
    if (origin) request.headers.set('origin', probeOrigin);
    if (auth && token != null) {
      request.headers.set('authorization', 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(const Duration(seconds: 45));
    final text = await utf8.decoder.bind(response).join();
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw ProbeError(
        'bad_response',
        'HTTP ${response.statusCode}, keine JSON-Antwort.',
      );
    }
    if (json is! Map<String, Object?>) {
      throw ProbeError(
        'bad_response',
        'HTTP ${response.statusCode}, unerwartete Antwort.',
      );
    }
    if (json['ok'] != true) {
      final error = json['error'];
      if (error is Map<String, Object?>) {
        throw ProbeError(
          '${error['code'] ?? 'unknown'}',
          '${error['message'] ?? 'Unbekannter Fehler.'}',
        );
      }
      throw ProbeError('unknown', 'HTTP ${response.statusCode}.');
    }
    return json;
  }

  /// Öffnet den Ereignisstrom (`/v1/events?token=`), wartet auf die Begrüßung.
  Future<WebSocket> events() async {
    final url = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/v1/events',
      queryParameters: <String, String>{'token': token ?? ''},
    );
    return WebSocket.connect(
      url.toString(),
      headers: <String, Object>{'origin': probeOrigin},
    ).timeout(const Duration(seconds: 10));
  }

  void close() => _client.close(force: true);
}

/// Findet den Agenten (HTTP-Port) und wählt HTTP oder HTTPS.
Future<ProbeConnection> _verbinden(ArgResults results, {String? token}) async {
  final festerPort = results['port'] as String?;
  final ports = festerPort != null
      ? <int>[_zahl(festerPort, 'port', min: 1)]
      : <int>[for (var p = 27182; p <= 27189; p++) p];
  final nurHttp = results['http'] as bool;

  for (final port in ports) {
    final http = ProbeConnection(
      Uri(scheme: 'http', host: '127.0.0.1', port: port),
      null,
    );
    Map<String, Object?> status;
    try {
      status = await http.call('GET', '/v1/status', origin: false, auth: false);
    } on Object {
      http.close();
      continue;
    }
    if (nurHttp) {
      http.close();
      return ProbeConnection(http.base, token);
    }
    http.close();
    final httpsPort = status['httpsPort'];
    if (httpsPort is! int) {
      throw ProbeError(
        'https_unavailable',
        'Der Agent lauscht nicht über HTTPS. Mit --http reines HTTP benutzen.',
      );
    }
    return ProbeConnection(
      Uri(scheme: 'https', host: '127.0.0.1', port: httpsPort),
      token,
    );
  }
  throw ProbeError(
    'agent_unreachable',
    festerPort != null
        ? 'Auf Port $festerPort antwortet kein Agent.'
        : 'Kein Agent auf 127.0.0.1:27182–27189 gefunden.',
  );
}

// -----------------------------------------------------------------------------
// Befehle

Future<void> _scan(ProbeConnection api, _Zeilen ausgabe) async {
  ausgabe.zeile('Suche läuft …');
  final antwort = await api.call(
    'POST',
    '/v1/bluetooth/scan',
    body: <String, Object?>{},
  );
  final devices = (antwort['devices'] as List?) ?? const <Object?>[];
  if (devices.isEmpty) ausgabe.zeile('Keine Geräte gefunden.');
  for (final raw in devices) {
    final d = raw as Map<String, Object?>;
    ausgabe.zeile(
      'Gerät ${d['id']}  Name ${d['name'] ?? '(ohne)'}  Signal ${d['rssi']}',
    );
  }
}

Future<void> _approve(
  ProbeConnection api,
  _Zeilen ausgabe,
  String id,
  String? name,
) async {
  final antwort = await api.call(
    'PUT',
    '/v1/bluetooth/devices/$id',
    body: <String, Object?>{if (name != null) 'name': name},
  );
  final d = antwort['device'] as Map<String, Object?>;
  ausgabe.zeile('Zugelassen: ${d['id']}  Name ${d['name'] ?? '(ohne)'}');
}

/// Gibt ein Ereignis des Stroms aus (Meldungen als Hex).
void _zeigeEreignis(_Zeilen ausgabe, String id, Object? raw) {
  if (raw is! String) return;
  Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return;
  }
  if (json is! Map<String, Object?>) return;
  final type = json['type'];
  if (type == 'hello') {
    ausgabe.zeile('Ereignisstrom verbunden.');
    return;
  }
  if (type is! String || !type.startsWith('bluetooth.')) return;
  final gemeint = json['id'];
  if (gemeint is String && gemeint.toLowerCase() != id) return;
  if (type == 'bluetooth.notification') {
    final data = base64Decode('${json['data']}');
    ausgabe.zeile(
      'Meldung ${_kurz('${json['characteristic']}')}  ${hexOf(data)}'
      '  (Verbindung ${json['generation']}, Nr. ${json['seq']})',
    );
    return;
  }
  final rest = Map<String, Object?>.of(json)..remove('type');
  ausgabe.zeile('Ereignis $type  ${jsonEncode(rest)}');
}

/// Kurzform einer UUID (`0000ff03-…` → `ff03`).
String _kurz(String uuid) {
  final m = RegExp(
    r'^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$',
  ).firstMatch(uuid);
  return m == null ? uuid : m.group(1)!;
}

Future<void> _abonnieren(
  ProbeConnection api,
  String id,
  _Zeilen ausgabe,
) async {
  final antwort = await api.call('POST', '/v1/bluetooth/devices/$id/connect');
  ausgabe.zeile('Verbunden (Verbindung ${antwort['generation']}).');
  await api.call(
    'POST',
    '/v1/bluetooth/devices/$id/subscribe',
    body: <String, Object?>{'service': _ff00, 'characteristic': _ff03},
  );
  ausgabe.zeile('Abo auf $_ff03 steht.');
}

Future<void> _watch(
  ProbeConnection api,
  _Zeilen ausgabe,
  String id,
  Stream<ProcessSignal> interrupt,
) async {
  final ws = await api.events();
  final ende = Completer<void>();
  final abo = ws.listen(
    (raw) => _zeigeEreignis(ausgabe, id, raw),
    onDone: () {
      if (!ende.isCompleted) ende.complete();
    },
  );
  final strgC = interrupt.listen((_) {
    if (!ende.isCompleted) ende.complete();
  });
  try {
    await _abonnieren(api, id, ausgabe);
    ausgabe.zeile('Ich schreibe mit, Ende mit Strg-C.');
    await ende.future;
    ausgabe.zeile('Ende.');
  } finally {
    await strgC.cancel();
    await abo.cancel();
    await ws.close();
  }
}

Future<int> _print(
  ProbeConnection api,
  _Zeilen ausgabe,
  Stopwatch uhr, {
  required String id,
  required String dateiPfad,
  required int paket,
  required bool mitAntwort,
  required int wartenSekunden,
  required int? abbrechenNach,
  required void Function(int code) hardExit,
  required Stream<ProcessSignal> interrupt,
}) async {
  final file = File(dateiPfad);
  if (!file.existsSync()) {
    throw ProbeUsageError('Die Datei $dateiPfad gibt es nicht.');
  }
  final data = parseHexText(file.readAsStringSync());
  final pakete = splitPackets(data, paket);
  if (pakete.isEmpty) throw ProbeUsageError('Die Datei enthält keine Bytes.');
  ausgabe.zeile(
    '${data.length} Byte in ${pakete.length} Paketen zu je höchstens $paket '
    '(${mitAntwort ? 'mit' : 'ohne'} Antwort).',
  );

  // Der Strom steht vor allem anderen, damit keine Meldung verloren geht.
  final ws = await api.events();
  final abo = ws.listen((raw) => _zeigeEreignis(ausgabe, id, raw));
  // Strg-C mitten im Senden: bewusst ohne Freigabe, so wie ein abgestürztes
  // Programm – getestet wird damit das Zurücksetzen der Belegung im Agenten.
  var hart = false;
  final strgC = interrupt.listen((_) {
    hart = true;
    ausgabe.zeile('Strg-C: Ende ohne Freigabe.');
    hardExit(130);
  });

  String? lease;
  Timer? erneuern;
  try {
    final belegung = await api.call(
      'POST',
      '/v1/bluetooth/devices/$id/lease',
      body: <String, Object?>{'waitMs': leaseWaitMs},
    );
    lease = belegung['lease'] as String;
    ausgabe.zeile('Belegung erhalten.');
    erneuern = Timer.periodic(leaseRenewInterval, (_) {
      api
          .call(
            'POST',
            '/v1/bluetooth/devices/$id/lease/renew',
            body: <String, Object?>{'lease': lease},
          )
          .catchError((Object e) {
            ausgabe.zeile('Belegung verlängern fehlgeschlagen: $e');
            return <String, Object?>{};
          });
    });

    final verbunden = await api.call(
      'POST',
      '/v1/bluetooth/devices/$id/connect',
    );
    final generation = verbunden['generation'];
    ausgabe.zeile('Verbunden (Verbindung $generation).');
    await api.call(
      'POST',
      '/v1/bluetooth/devices/$id/subscribe',
      body: <String, Object?>{'service': _ff00, 'characteristic': _ff03},
    );
    ausgabe.zeile('Abo auf $_ff03 steht.');

    for (var i = 0; i < pakete.length; i++) {
      if (abbrechenNach != null && i >= abbrechenNach) {
        hart = true;
        ausgabe.zeile('Abbruch nach $i Paketen, ohne Freigabe.');
        hardExit(2);
        throw ProbeError('abgebrochen', 'Ende ohne Freigabe.');
      }
      await api.call(
        'POST',
        '/v1/bluetooth/devices/$id/write',
        body: <String, Object?>{
          'service': _ff00,
          'characteristic': _ff02,
          'withResponse': mitAntwort,
          'lease': lease,
          'generation': generation,
          'data': base64Encode(pakete[i]),
        },
      );
      ausgabe.zeile(
        'Paket ${i + 1}/${pakete.length} geschrieben (${pakete[i].length} Byte).',
      );
    }
    if (abbrechenNach != null && abbrechenNach >= pakete.length) {
      hart = true;
      ausgabe.zeile('Abbruch nach allen Paketen, ohne Freigabe.');
      hardExit(2);
      throw ProbeError('abgebrochen', 'Ende ohne Freigabe.');
    }

    ausgabe.zeile(
      'Alle Pakete gesendet, warte $wartenSekunden s auf Meldungen.',
    );
    await Future<void>.delayed(Duration(seconds: wartenSekunden));
    return 0;
  } finally {
    erneuern?.cancel();
    await strgC.cancel();
    // `hardExit` kehrt im Betrieb nie zurück; das Kennzeichen schützt nur vor
    // der Freigabe, wenn ein Test den Abbruch als Ausnahme nachstellt.
    if (!hart && lease != null) {
      try {
        final r = await api.call(
          'POST',
          '/v1/bluetooth/devices/$id/lease/release',
          body: <String, Object?>{'lease': lease},
        );
        ausgabe.zeile('Belegung freigegeben (${r['released']}).');
      } on Object catch (e) {
        ausgabe.zeile('Freigabe fehlgeschlagen: $e');
      }
    }
    await abo.cancel();
    if (!hart) await ws.close();
  }
}
