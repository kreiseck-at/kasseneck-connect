import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log/logger.dart';
import '../lokales_netz.dart';

/// Hobex-HPS-Terminals sprechen JSON-REST über HTTP auf diesem Port.
const int hpsDefaultPort = 8080;

/// Terminal am Netz, antwortet aber nicht wie erwartet / meldet einen Fehler.
const String errorTerminalError = 'terminal_error';

/// Die Verbindung zum Terminal stand und ist danach abgerissen (Netz weg,
/// Terminal neu gestartet). Ob die Anfrage angekommen ist, ist OFFEN — die
/// Kasse behandelt den Ausgang als ungeklärt.
///
/// Bis 1.4.1 kam dieser Code auch, wenn gar keine Verbindung zustande kam;
/// das meldet jetzt [errorTerminalUnreachable].
const String errorTerminalOffline = 'terminal_offline';

/// Das Terminal hat nicht rechtzeitig geantwortet. Die Verbindung stand, die
/// Anfrage kann also angekommen sein: Ausgang offen.
const String errorTerminalTimeout = 'timeout';

/// Keine Verbindung zum Terminal: der TCP-Aufbau scheiterte (abgelehnt, keine
/// Route, Name unbekannt) oder lief in sein Zeitlimit
/// ([hpsVerbindungTimeout]). Es wurde **nachweislich nichts gesendet** — die
/// Kasse darf das wie einen Fehler vor dem Terminal-Kontakt behandeln: nichts
/// belastet, erneut versuchen ist gefahrlos.
///
/// Warum das in Dart gilt (nachgelesen im Dart-SDK 3.12.1,
/// `sdk/lib/_http/http_impl.dart`):
///
/// - `HttpClient.openUrl` (`_HttpClient._openUrl`) liefert erst, wenn
///   `_ConnectionTarget.connect` einen VERBUNDENEN Socket hat; ein Fehler
///   oder `connectionTimeout` beim Aufbau endet dort als `SocketException`
///   ("HTTP connection timed out after …") und erreicht den Aufrufer über
///   genau diesen Future.
/// - Erst danach baut `_HttpClientConnection.send` das `HttpClientRequest`
///   über einem `_HttpOutgoing` mit `headersWritten = false`. Kopf und Rumpf
///   gehen frühestens beim ersten `add`/`write` (`addStream` →
///   `writeHeaders`) oder bei `close()` hinaus — beides ruft [HpsBridge] erst
///   NACH dem erfüllten `openUrl` auf.
/// - Jeder Aufruf hat seinen eigenen `HttpClient`: eine wiederverwendete,
///   schon benutzte Verbindung kann `openUrl` nie liefern. Ein Proxy ist
///   ausgeschaltet (`findProxy` → `DIRECT`), die Verbindung geht also
///   wirklich zum Terminal und nicht zu einem Zwischenhalt.
/// - TCP Fast Open (Daten schon im SYN) nutzt Dart nicht.
///
/// Fehler NACH aufgebauter Verbindung behalten ihre Codes
/// ([errorTerminalOffline], [errorTerminalTimeout], [errorTerminalError]) —
/// dort ist der Ausgang offen.
const String errorTerminalUnreachable = 'terminal_unreachable';

/// Zeitlimit für den TCP-Verbindungsaufbau, für jeden Aufruf (auch Zahlung
/// und Gutschrift; deren lange Frist gilt erst für die Antwort).
///
/// Im Kassen-Netz steht eine Verbindung in Millisekunden. 10 s reichen auch
/// für ein Terminal, dessen WLAN gerade schläft: verschluckt es das SYN,
/// wiederholt der Rechner es nach rund 1, 3 und 7 s — bis 10 s sind das drei
/// Weckversuche auf TCP-Ebene. Länger zu warten hilft nicht: ein Terminal,
/// das so lange gar nicht antwortet, ist aus, woanders oder hat eine andere
/// IP. Vorher blockierte eine falsche IP die Zahlung bis zu 4 Minuten.
/// Dasselbe Maß wie Druckauftrag und Bluetooth-Aufbau im übrigen Agenten.
const Duration hpsVerbindungTimeout = Duration(seconds: 10);

/// Kurze Aufrufe (Erreichbarkeit, Diagnose, Status, Abbruch). Die Diagnose
/// fragt beim Autorisierungs-Host nach und darf ein paar Sekunden brauchen.
const Duration hpsKurzTimeout = Duration(seconds: 15);

/// Eine Zahlung blockiert, bis der Kartenflow am Terminal fertig ist — das
/// HPS selbst rechnet mit bis zu drei Minuten (Karte, PIN, Autorisierung).
const Duration hpsZahlungTimeout = Duration(minutes: 4);

/// Fehler auf dem Weg zum Terminal — `code` für die Kasse, `message` deutsch.
class HpsWegFehler implements Exception {
  HpsWegFehler(this.code, this.message, {this.terminalHttpStatus});

  final String code;
  final String message;

  /// Der rohe HTTP-Status des Terminals, wenn es einen genannt hat.
  ///
  /// Warum als eigenes Feld und nicht nur im Meldungstext: Die Kasse muss
  /// `409` ("Terminal is busy") von jedem anderen Fehler unterscheiden können,
  /// weil `409` gemessen eine ECHTE Aussage ist — die Anfrage wurde nach rund
  /// 87 ms abgewiesen und hinterlässt keine Spur, es ist also nachweislich
  /// nichts belastet. Jeder andere Fehler lässt den Ausgang offen.
  ///
  /// Diesen Unterschied aus dem deutschen Meldungstext zu lesen, wäre eine
  /// Kopplung an eine Formulierung: ändert sie sich hier, fiele die Kasse
  /// lautlos auf "ungeklärt" zurück — sicher, aber unbemerkt. Ein
  /// Weiterleiter, der den Status verschluckt und nur Prosa übrig lässt,
  /// leitet nicht treu weiter.
  final int? terminalHttpStatus;

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
  HpsBridge({
    required this.log,
    this.kurzTimeout = hpsKurzTimeout,
    this.zahlungTimeout = hpsZahlungTimeout,
    this.verbindungTimeout = hpsVerbindungTimeout,
    String? betriebssystem,
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? verbinden,
  }) : betriebssystem = betriebssystem ?? Platform.operatingSystem,
       _verbinden = verbinden;

  final AgentLog log;

  /// Zeitlimit der kurzen Aufrufe (Tests setzen es herab).
  final Duration kurzTimeout;

  /// Zeitlimit für die Antwort auf Zahlung und Gutschrift (Tests setzen es
  /// herab).
  final Duration zahlungTimeout;

  /// Zeitlimit des Verbindungsaufbaus — nie länger als die Frist des
  /// Aufrufs selbst. Siehe [hpsVerbindungTimeout].
  final Duration verbindungTimeout;

  /// Betriebssystem für den Hinweis auf die Freigabe „Lokales Netzwerk“
  /// (macOS); Tests setzen es fest.
  final String betriebssystem;

  /// Nur für Tests: ersetzt den Verbindungsaufbau des `HttpClient`
  /// (`HttpClient.connectionFactory`), etwa durch einen, der nie fertig wird.
  final Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? _verbinden;

  /// Kurzer Aufruf mit EINEM Weckversuch: ein Terminal im WLAN-Stromsparmodus
  /// verschlaeft gern die erste Anfrage (sie weckt nur das Funkmodul) und
  /// antwortet auf die zweite in Millisekunden — belegt am Geraet. Zahlungen
  /// bekommen diesen Automatismus bewusst NICHT (nie doppelt ausloesen).
  ///
  /// Ein verschlafenes Terminal kann jeden der drei Transportfehler auslösen:
  /// keine Verbindung (`terminal_unreachable`), Verbindung abgerissen
  /// (`terminal_offline`) oder keine Antwort (`timeout`).
  Future<Object?> _kurzMitWeckversuch(Future<Object?> Function() aufruf) async {
    try {
      return await aufruf();
    } on HpsWegFehler catch (e) {
      if (e.code != errorTerminalTimeout &&
          e.code != errorTerminalOffline &&
          e.code != errorTerminalUnreachable) {
        rethrow;
      }
      log.info('Terminal verschlafen? Zweiter Versuch nach ${e.code}.');
      return await aufruf();
    }
  }

  /// Erkennungs-Probe ohne TID: `GET /api/terminals/0/diagnosis`.
  ///
  /// Das echte HPS (belegt an hps 1.10.0) antwortet darauf mit HTTP 200 und
  /// `{"responseCode":"100108","responseText":"Invalid TID","tid":"0"}` —
  /// keine Zahlung, keine Nebenwirkung, und die Form der Antwort verrät das
  /// Terminal. Ein `GET /api/terminals` gibt es am Terminal NICHT ("Endpoint
  /// not implemented", 404) — den Endpunkt kennt nur die Hobex-Cloud-API.
  Future<Object?> probe({required String host, required int port}) {
    return _kurzMitWeckversuch(
      () => _call('GET', host, port, '/api/terminals/0/diagnosis'),
    );
  }

  /// `GET /api/terminals/{tid}/diagnosis` — Diagnose ohne Zahlung; das
  /// Terminal prüft dabei auch die Verbindung zum Autorisierungs-Host.
  ///
  /// [frist] ersetzt die Frist der kurzen Aufrufe (Diagnose vor einer
  /// umgeleiteten Zahlung: kurz, damit sie nie lange aufhält).
  Future<Object?> diagnosis({
    required String host,
    required int port,
    required String tid,
    Duration? frist,
  }) {
    return _call(
      'GET',
      host,
      port,
      '/api/terminals/$tid/diagnosis',
      timeout: frist,
    );
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
      timeout: zahlungTimeout,
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

  /// `POST /api/transaction/refund` — Gutschrift. Ein KARTENFLUSS wie
  /// [payment] (das Terminal spielt Geld an die Karte zurück), deshalb
  /// dieselbe lange Frist. Beträge kommen als Cent herein und gehen als
  /// Euro-Zahl hinaus, wie bei [payment].
  ///
  /// Die Kennung der Gutschrift ([transactionId]) ist eine EIGENE, neue —
  /// [originalTransactionId] verweist auf die erstattete Zahlung. Auf eine
  /// unbekannte Original-Kennung antwortet das Terminal `9002` "Invalid
  /// Transaction": kein Kartenfluss, keine Auszahlung (gemessen 27.08.2026,
  /// Testterminal, HPS 1.10.0, FW 7.3.6, Antwort nach 1,2 s).
  Future<Object?> refund({
    required String host,
    required int port,
    required String tid,
    required int amountCents,
    required String transactionId,
    required String originalTransactionId,
    String? reference,
    String currency = 'EUR',
    String? language,
  }) {
    final transaction = <String, Object?>{
      'transactionId': transactionId,
      'tid': tid,
      'currency': currency,
      'amount': amountCents / 100,
      'originalTransactionId': originalTransactionId,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
      if (language != null) 'language': language,
    };
    return _call(
      'POST',
      host,
      port,
      '/api/transaction/refund',
      body: <String, Object?>{'transaction': transaction},
      timeout: zahlungTimeout,
    );
  }

  /// `DELETE /api/transaction/payment/{tid}/{transactionId}` — Aufhebung
  /// (Storno/Void) einer bestehenden Zahlung. Kurzer Aufruf, keine
  /// Karteninteraktion.
  ///
  /// [transactionId] ist hier die Kennung der URSPRUENGLICHEN Zahlung, nicht
  /// die eines neuen Vorgangs. `amount`, `currency` und optional `language`
  /// gehen als QUERY-Parameter mit — anders als bei [payment]/[refund], die
  /// einen JSON-Rumpf schicken.
  ///
  /// [amountCents] ist PFLICHT: ein Void ohne Betrag weist das Terminal mit
  /// `400 Missing amount` ab (gemessen 27.08.2026, Testterminal, HPS 1.10.0,
  /// FW 7.3.6). Einen falschen Betrag prueft es dabei NICHT gegen das
  /// Original — ein Void mit abweichendem Betrag wurde ebenso mit `0`
  /// beantwortet. Ein zweiter Void auf eine bereits aufgehobene Zahlung ist
  /// KEIN Fehler (`0` "Tx Canceled"), ein Void auf eine unbekannte Kennung
  /// antwortet `9002` "Invalid Transaction".
  Future<Object?> cancel({
    required String host,
    required int port,
    required String tid,
    required String transactionId,
    required int amountCents,
    String currency = 'EUR',
    String? language,
  }) {
    final query = <String, String>{
      'amount': (amountCents / 100).toString(),
      'currency': currency,
      if (language != null) 'language': language,
    };
    return _call(
      'DELETE',
      host,
      port,
      '/api/transaction/payment/$tid/$transactionId',
      query: query,
    );
  }

  Future<Object?> _call(
    String method,
    String host,
    int port,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    // Eine Frist für den ganzen Aufruf – Aufbau, Kopf und Rumpf zusammen.
    // Je Abschnitt eine eigene hieße bei der Zahlung bis zu zweimal vier
    // Minuten, und die Belegung des Terminals liefe vorher ab.
    final zeitlimit = timeout ?? kurzTimeout;
    final uhr = Stopwatch()..start();
    Duration rest() {
      final r = zeitlimit - uhr.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    final aufbauLimit = verbindungTimeout < zeitlimit
        ? verbindungTimeout
        : zeitlimit;
    final client = HttpClient()
      ..connectionTimeout = aufbauLimit
      // Das Terminal steht im lokalen Netz; ein Proxy aus der Umgebung
      // (`http_proxy`) hätte dort nichts verloren und machte aus „verbunden“
      // „mit dem Proxy verbunden“ — siehe errorTerminalUnreachable.
      ..findProxy = (Uri _) => 'DIRECT';
    final verbinden = _verbinden;
    if (verbinden != null) client.connectionFactory = verbinden;
    try {
      final uri = Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
        queryParameters: query,
      );
      final request = await _oeffnen(client, method, uri, aufbauLimit);
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
      final response = await request.close().timeout(rest());
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(rest());

      Object? daten;
      try {
        daten = text.trim().isEmpty ? null : jsonDecode(text);
      } on FormatException {
        throw HpsWegFehler(
          errorTerminalError,
          'Das Terminal antwortet, aber nicht im HPS-Format – '
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
          terminalHttpStatus: response.statusCode,
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
      // Die Verbindung stand schon (sonst hätte _oeffnen gemeldet): ob die
      // Anfrage angekommen ist, weiß hier niemand.
      log.info('HPS $host:$port: Verbindung abgerissen: ${socketGrund(e)}');
      throw HpsWegFehler(
        errorTerminalOffline,
        'Die Verbindung zum Terminal unter $host:$port ist abgerissen – ob '
        'die Anfrage angekommen ist, ist offen.',
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

  /// Die Verbindungsphase: scheitert sie, ist nachweislich nichts gesendet
  /// (siehe [errorTerminalUnreachable]) — und nur dann entsteht dieser Code.
  ///
  /// [limit] deckt den ganzen Aufbau ab, auch eine Namensauflösung, die vor
  /// dem `connectionTimeout` des `HttpClient` liegt.
  Future<HttpClientRequest> _oeffnen(
    HttpClient client,
    String method,
    Uri uri,
    Duration limit,
  ) async {
    try {
      return await client.openUrl(method, uri).timeout(limit);
    } on SocketException catch (e) {
      throw _unerreichbar(uri, e, socketGrund(e));
    } on TimeoutException catch (e) {
      throw _unerreichbar(
        uri,
        e,
        'kein Verbindungsaufbau in ${limit.inMilliseconds} ms',
      );
    }
  }

  HpsWegFehler _unerreichbar(Uri uri, Object ursache, String grund) {
    final ziel = '${uri.host}:${uri.port}';
    log.info('HPS $ziel: keine Verbindung ($grund) – nichts gesendet.');
    return HpsWegFehler(
      errorTerminalUnreachable,
      mitLokalesNetzHinweis(
        'Keine Verbindung zum Terminal unter $ziel – es wurde nichts '
        'gesendet. Bitte prüfen, ob das Terminal eingeschaltet und im selben '
        'Netz ist und die IP-Adresse stimmt.',
        ursache,
        betriebssystem: betriebssystem,
      ),
    );
  }
}

/// Sieht [antwort] nach einem Hobex-HPS aus? (JSON-Objekt mit `responseCode` —
/// so antwortet das Terminal auch auf die TID-lose Probe.)
bool siehtNachHpsAus(Object? antwort) =>
    antwort is Map && antwort['responseCode'] != null;
