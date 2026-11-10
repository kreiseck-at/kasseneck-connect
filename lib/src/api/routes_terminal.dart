import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../betrieb/vorgaenge.dart';
import '../config/model.dart';
import '../config/neuerungen.dart';
import '../terminal/belegung.dart';
import '../terminal/discovery.dart';
import '../terminal/hps.dart';
import '../terminal/tid.dart';
import '../terminal/warmhalten.dart';
import '../terminal/wiederfinden.dart';
import 'auth.dart';
import 'context.dart';
import 'responses.dart';

/// Erlaubte Form eines Hosts (IP oder Hostname) — keine Pfade, keine Ports,
/// keine Leerzeichen: der Wert landet in einer URL.
final RegExp _host = RegExp(r'^[A-Za-z0-9.\-]{1,253}$');

/// TID laut Spec: Ziffern (ohne führende Null gepflegt, das prüft die Kasse).
final RegExp _tid = RegExp(r'^\d{1,16}$');

/// Transaktions-ID: numerisch, höchstens 18 Stellen (Spec).
final RegExp _transactionId = RegExp(r'^\d{1,18}$');

/// Connect hält gerade einen langen Aufruf für dieses Terminal (ab 1.5.0).
const String errorTerminalBusy = 'terminal_busy';

/// Den rohen Status, den das Terminal selbst bei „beschäftigt“ nennt (409),
/// trägt auch [errorTerminalBusy]: eine Kasse, die den Code noch nicht kennt,
/// liest daran „nachweislich nichts belastet“ – wie bei der Antwort des
/// Terminals, die sie ohne Connect bekäme.
const int terminalBusyHttpStatus = 409;

/// Meldet die Terminal-Endpunkte (Hobex HPS) am Router an.
///
/// Alle Pfade sind token- und herkunftsgeschützt — wer drucken darf, darf
/// auch das Terminal ansprechen; einen eigenen Vertrauenskreis gibt es nicht.
/// Die Brücke reicht die HPS-Antwort unverändert als `hps` durch.
///
/// Ab 1.5.0 (siehe [_Terminal]): ein langer Aufruf belegt das Terminal
/// ([TerminalBelegung], `busy_lock`), ein Aufruf ohne Verbindung wird genau
/// einmal an die bestätigte Adresse derselben TID umgeleitet und jede Antwort
/// nennt die benutzte Adresse (`endpoint`, `terminal_relocate`).
RouteRegistrar terminalRoutes({
  HpsBridge? bridge,
  // Haelt das Terminal nach dem ersten erfolgreichen Kontakt wach.
  TerminalWarmhalter? warmhalter,
  // Nur für Tests: die echte Suche scannt das Netz des Rechners.
  Future<TerminalDiscoveryResult> Function(HpsBridge, AgentContext)? discover,
  TerminalBelegung? belegung,
  TerminalWiederfinder? wiederfinder,
  LaufendeVorgaenge? vorgaenge,
}) {
  return (Router router, AgentContext ctx) {
    final hps = bridge ?? HpsBridge(log: ctx.log);
    final suche =
        discover ??
        (HpsBridge h, AgentContext c) =>
            discoverTerminals(bridge: h, log: c.log);
    final t = _Terminal(
      hps: hps,
      ctx: ctx,
      warmhalter: warmhalter,
      belegung: belegung ?? TerminalBelegung(clock: ctx.clock),
      wiederfinder: wiederfinder,
      vorgaenge: vorgaenge,
    );

    router
      ..post('/v1/terminal/test', (Request r) => _handleTest(t, r))
      ..post(
        '/v1/terminal/discover',
        (Request r) => _handleDiscover(t, suche, r),
      )
      ..post('/v1/terminal/diagnosis', (Request r) => _handleDiagnosis(t, r))
      ..post('/v1/terminal/payment', (Request r) => _handlePayment(t, r))
      ..post('/v1/terminal/status', (Request r) => _handleStatus(t, r))
      ..post('/v1/terminal/abort', (Request r) => _handleAbort(t, r))
      ..post('/v1/terminal/refund', (Request r) => _handleRefund(t, r))
      ..post('/v1/terminal/cancel', (Request r) => _handleCancel(t, r))
      ..post('/v1/terminal/locate', (Request r) => _handleLocate(t, r));
  };
}

/// Alles, was die Terminal-Routen teilen.
class _Terminal {
  _Terminal({
    required this.hps,
    required this.ctx,
    required this.warmhalter,
    required this.belegung,
    required this.wiederfinder,
    required this.vorgaenge,
  });

  final HpsBridge hps;
  final AgentContext ctx;
  final TerminalWarmhalter? warmhalter;
  final TerminalBelegung belegung;
  final TerminalWiederfinder? wiederfinder;

  /// Zählt lange Aufrufe als laufende Vorgänge (Update- und Schlafsperre).
  final LaufendeVorgaenge? vorgaenge;

  /// `terminal_busy`: nachweislich nichts gesendet.
  Response besetzt() => failJson(
    errorTerminalBusy,
    'Am Terminal läuft gerade ein Vorgang – bitte kurz warten.',
    detail: const <String, Object?>{
      'terminalHttpStatus': terminalBusyHttpStatus,
    },
  );

  /// Ob die Belegung gilt (Not-Aus `busy_lock`).
  bool sperrtBei(Request request) =>
      configOf(request).aktiv(Neuerung.betriebSperre);

  /// Führt [aufruf] an [ziel] aus und baut die Antwort.
  ///
  /// Kommt keine Verbindung zustande (`terminal_unreachable`, nachweislich
  /// nichts gesendet) und kennt Connect für [tid] eine andere, höchstens 24 h
  /// alt bestätigte Adresse, läuft derselbe Aufruf dort genau einmal – auch
  /// Zahlung und Gutschrift. Ein Netzscan läuft hier nie.
  Future<Response> ausfuehren(
    Request request,
    (String, int) ziel, {
    required Future<Object?> Function(String host, int port) aufruf,
    String? tid,
    bool merken = false,
  }) async {
    final config = configOf(request);
    final umleiten = config.aktiv(Neuerung.terminalWiederfinden);
    var host = ziel.$1;
    var port = ziel.$2;
    var umgeleitet = false;
    Map<String, Object?> endpoint() => <String, Object?>{
      'endpoint': <String, Object?>{
        'host': host,
        'port': port,
        'relocated': umgeleitet,
      },
    };

    Object? daten;
    try {
      try {
        daten = await aufruf(host, port);
      } on HpsWegFehler catch (e) {
        if (e.code != errorTerminalUnreachable || !umleiten || tid == null) {
          rethrow;
        }
        final alt = umleitungsZiel(
          host: host,
          port: port,
          tid: tid,
          gemerkt: config.terminal,
          jetzt: ctx.clock(),
        );
        if (alt == null) rethrow;
        ctx.log.info(
          'Terminal $tid: keine Verbindung unter $host:$port – derselbe '
          'Aufruf geht an die bestätigte Adresse ${alt.host}:${alt.port}.',
        );
        host = alt.host;
        port = alt.port;
        umgeleitet = true;
        daten = await aufruf(host, port);
      }
    } on HpsWegFehler catch (e) {
      // Den rohen Terminal-Status mitgeben, wo es einen gab: die Kasse
      // unterscheidet daran `409` ("Terminal is busy", nachweislich nichts
      // belastet) von jedem anderen Fehler, der den Ausgang offen laesst.
      // Siehe HpsWegFehler.terminalHttpStatus.
      return failJson(
        e.code,
        e.message,
        detail: e.terminalHttpStatus == null
            ? null
            : <String, Object?>{'terminalHttpStatus': e.terminalHttpStatus},
        zusatz: umleiten ? endpoint() : null,
      );
    }
    if (merken) {
      final bestaetigt = tid != null && tidBestaetigt(daten, tid);
      warmhalter?.merken(
        host,
        port,
        tid: tid,
        bestaetigt: bestaetigt,
        serie: bestaetigt ? terminalSerie(daten) : null,
      );
    }
    return okJson(<String, Object?>{'hps': daten, if (umleiten) ...endpoint()});
  }

  /// Ein kurzer Aufruf (Diagnose, Test): `terminal_busy`, solange ein langer
  /// das Terminal belegt; sonst angemeldet, damit eine Zahlung ihn abwartet.
  Future<Response> kurz(
    Request request,
    (String, int) ziel, {
    required String? tid,
    required Future<Object?> Function(String host, int port) aufruf,
  }) async {
    if (!sperrtBei(request)) {
      return ausfuehren(request, ziel, aufruf: aufruf, tid: tid, merken: true);
    }
    final angemeldet = belegung.kurzBeginnen(
      tid: tid,
      host: ziel.$1,
      port: ziel.$2,
    );
    if (angemeldet == null) return besetzt();
    try {
      return await ausfuehren(
        request,
        ziel,
        aufruf: aufruf,
        tid: tid,
        merken: true,
      );
    } finally {
      belegung.kurzBeenden(angemeldet);
    }
  }

  /// Ein langer Aufruf: belegt das Terminal für seine Dauer und zählt als
  /// laufender Vorgang.
  Future<Response> lang(
    Request request,
    (String, int) ziel, {
    required String tid,
    required LangerAufruf art,
    required Future<Object?> Function(String host, int port) aufruf,
    bool merken = false,
  }) async {
    TerminalBeleg? beleg;
    if (sperrtBei(request)) {
      beleg = belegung.belegen(
        tid: tid,
        host: ziel.$1,
        port: ziel.$2,
        art: art,
      );
      if (beleg == null) return besetzt();
    }
    final vorgang = vorgaenge?.beginne(VorgangsArt.terminal);
    try {
      // Neue kurze Aufrufe lehnt die Belegung ab jetzt ab; die schon
      // unterwegs sind, laufen zu Ende, bevor die Zahlung hinausgeht.
      if (beleg != null) {
        await belegung.kurzeAbwarten(tid: tid, host: ziel.$1, port: ziel.$2);
      }
      return await ausfuehren(
        request,
        ziel,
        aufruf: aufruf,
        tid: tid,
        merken: merken,
      );
    } finally {
      if (vorgang != null) vorgaenge?.beende(vorgang);
      if (beleg != null) belegung.freigeben(beleg);
    }
  }
}

/// Die TID aus dem Rumpf in der Form, die das Terminal annimmt.
///
/// Gerätetest HPS 1.14.4: `03600335` lehnt es mit `100108 Invalid TID` ab,
/// `3600335` geht. Führende Nullen fallen deshalb weg (nur bei einer reinen
/// Ziffernfolge, `0` bleibt `0`); gemerkt und verglichen wird ebenfalls diese
/// Form. Das Paket der Kasse normiert genauso – hier doppelt, damit auch eine
/// ältere Kasse zahlt.
String _tidAus(Object? roh) => tidNormal(readString(roh)?.trim() ?? '');

/// Host und Port aus dem Rumpf; `null` + fertige Fehlerantwort bei Unsinn.
(String, int)? _ziel(Map<String, Object?> body) {
  final host = readString(body['host'])?.trim() ?? '';
  final portRoh = body['port'];
  final port = portRoh == null
      ? hpsDefaultPort
      : (portRoh is int ? portRoh : -1);
  if (!_host.hasMatch(host) || port < 1 || port > 65535) return null;
  return (host, port);
}

Response _zielFehler() => failJson(
  errorBadRequest,
  'Es fehlt die Adresse des Terminals (host, optional port).',
);

/// `POST /v1/terminal/test` `{host, port?, tid?}` — Erreichbarkeit.
///
/// Ohne TID die nebenwirkungsfreie Probe (`/api/terminals/0/diagnosis`,
/// Antwort „Invalid TID“ beweist das HPS); mit TID die echte Diagnose samt
/// Gerätestatus. Antwortet die Gegenstelle zwar, aber nicht im HPS-Format,
/// ist es kein Terminal (`terminal_error`).
Future<Response> _handleTest(_Terminal t, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final ziel = _ziel(body.data!);
  if (ziel == null) return _zielFehler();
  final tid = _tidAus(body.data!['tid']);
  return t.kurz(
    request,
    ziel,
    tid: tid.isEmpty ? null : tid,
    aufruf: (host, port) async {
      final antwort = tid.isEmpty
          ? await t.hps.probe(host: host, port: port)
          : await t.hps.diagnosis(host: host, port: port, tid: tid);
      if (!siehtNachHpsAus(antwort)) {
        throw HpsWegFehler(
          errorTerminalError,
          'Unter $host:$port antwortet etwas – aber kein Hobex-Terminal.',
        );
      }
      return antwort;
    },
  );
}

/// `POST /v1/terminal/diagnosis` `{host, port?, tid}`.
Future<Response> _handleDiagnosis(_Terminal t, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final ziel = _ziel(body.data!);
  if (ziel == null) return _zielFehler();
  final tid = _tidAus(body.data!['tid']);
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  return t.kurz(
    request,
    ziel,
    tid: tid,
    aufruf: (host, port) => t.hps.diagnosis(host: host, port: port, tid: tid),
  );
}

/// `POST /v1/terminal/payment`
/// `{host, port?, tid, amountCents, transactionId, tipCents?, reference?,
///   currency?, language?}` — blockiert bis zum Ende des Kartenflows.
///
/// `transactionId` MUSS die Kasse vergeben und sich merken: sie ist der
/// einzige Schlüssel für Status-Abfrage und Storno, wenn der lange Aufruf
/// reißt. Eine Ablehnung kommt als `ok:true` mit `responseCode != "0"` im
/// `hps`-Rumpf zurück — abgelehnt ist eine Antwort, kein Transportfehler.
///
/// Transportfehler: `terminal_unreachable` heißt „keine Verbindung, nichts
/// gesendet“; `terminal_offline`, `timeout` und `terminal_error` (außer
/// `detail.terminalHttpStatus == 409`) lassen den Ausgang offen — dann über
/// `/v1/terminal/status` klären, nie blind neu zahlen.
Future<Response> _handlePayment(_Terminal t, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final daten = body.data!;
  final ziel = _ziel(daten);
  if (ziel == null) return _zielFehler();

  final tid = _tidAus(daten['tid']);
  final transactionId = readString(daten['transactionId'])?.trim() ?? '';
  final amountCents = daten['amountCents'];
  final tipCents = daten['tipCents'];
  final currency = readString(daten['currency'])?.trim();
  final language = readString(daten['language'])?.trim();
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  if (!_transactionId.hasMatch(transactionId)) {
    return failJson(
      errorBadRequest,
      'Es fehlt die Transaktions-ID (transactionId, Ziffern, höchstens 18).',
    );
  }
  if (amountCents is! int || amountCents <= 0 || amountCents > 100000000) {
    return failJson(errorBadRequest, 'Es fehlt der Betrag (amountCents > 0).');
  }
  if (tipCents != null && (tipCents is! int || tipCents < 0)) {
    return failJson(errorBadRequest, 'Trinkgeld (tipCents) muss ≥ 0 sein.');
  }
  if (currency != null && !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
    return failJson(errorBadRequest, 'Währung bitte als ISO-Code (EUR).');
  }
  if (language != null && !RegExp(r'^(DE|IT|SI)$').hasMatch(language)) {
    return failJson(errorBadRequest, 'Sprache: DE, IT oder SI.');
  }

  return t.lang(
    request,
    ziel,
    tid: tid,
    art: LangerAufruf.zahlung,
    merken: true,
    aufruf: (host, port) => t.hps.payment(
      host: host,
      port: port,
      tid: tid,
      amountCents: amountCents,
      transactionId: transactionId,
      tipCents: tipCents as int?,
      reference: readString(daten['reference'])?.trim(),
      currency: currency ?? 'EUR',
      language: language,
    ),
  );
}

/// `POST /v1/terminal/refund`
/// `{host, port?, tid, amountCents, transactionId, originalTransactionId,
///   reference?, currency?, language?}` — Gutschrift, ein Kartenfluss wie
/// die Zahlung und deshalb mit derselben langen Frist unterwegs.
///
/// `transactionId` ist die NEUE Kennung der Gutschrift, die die Kasse
/// vergibt und sich merkt; `originalTransactionId` verweist auf die
/// erstattete Zahlung — beide müssen die Kasse mitbringen, keine wird hier
/// erzeugt.
Future<Response> _handleRefund(_Terminal t, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final daten = body.data!;
  final ziel = _ziel(daten);
  if (ziel == null) return _zielFehler();

  final tid = _tidAus(daten['tid']);
  final transactionId = readString(daten['transactionId'])?.trim() ?? '';
  final originalTransactionId =
      readString(daten['originalTransactionId'])?.trim() ?? '';
  final amountCents = daten['amountCents'];
  final currency = readString(daten['currency'])?.trim();
  final language = readString(daten['language'])?.trim();
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  if (!_transactionId.hasMatch(transactionId)) {
    return failJson(
      errorBadRequest,
      'Es fehlt die Transaktions-ID (transactionId, Ziffern, höchstens 18).',
    );
  }
  if (!_transactionId.hasMatch(originalTransactionId)) {
    return failJson(
      errorBadRequest,
      'Es fehlt die Kennung der Original-Zahlung (originalTransactionId, '
      'Ziffern, höchstens 18).',
    );
  }
  if (amountCents is! int || amountCents <= 0 || amountCents > 100000000) {
    return failJson(errorBadRequest, 'Es fehlt der Betrag (amountCents > 0).');
  }
  if (currency != null && !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
    return failJson(errorBadRequest, 'Währung bitte als ISO-Code (EUR).');
  }
  if (language != null && !RegExp(r'^(DE|IT|SI)$').hasMatch(language)) {
    return failJson(errorBadRequest, 'Sprache: DE, IT oder SI.');
  }

  return t.lang(
    request,
    ziel,
    tid: tid,
    art: LangerAufruf.gutschrift,
    merken: true,
    aufruf: (host, port) => t.hps.refund(
      host: host,
      port: port,
      tid: tid,
      amountCents: amountCents,
      transactionId: transactionId,
      originalTransactionId: originalTransactionId,
      reference: readString(daten['reference'])?.trim(),
      currency: currency ?? 'EUR',
      language: language,
    ),
  );
}

/// `POST /v1/terminal/status` `{host, port?, tid, transactionId}`.
///
/// Bewusst nie `terminal_busy`: mit dieser Abfrage klärt die Kasse genau die
/// Zahlung, die gerade läuft oder eben gerissen ist.
Future<Response> _handleStatus(_Terminal t, Request request) => _mitTransaktion(
  t,
  request,
  (host, port, tid, txId) {
    return t.hps.status(host: host, port: port, tid: tid, transactionId: txId);
  },
);

/// `POST /v1/terminal/abort` `{host, port?, tid, transactionId}`.
///
/// Bewusst nie `terminal_busy`: der Abbruch gilt der laufenden Zahlung.
Future<Response> _handleAbort(_Terminal t, Request request) =>
    _mitTransaktion(t, request, (host, port, tid, txId) {
      return t.hps.abort(host: host, port: port, tid: tid, transactionId: txId);
    });

/// `POST /v1/terminal/cancel`
/// `{host, port?, tid, transactionId, amountCents, currency?, language?}`
/// — Aufhebung (Storno/Void), ein kurzer Aufruf ohne Karteninteraktion.
///
/// `transactionId` ist hier die Kennung der URSPRUENGLICHEN Zahlung, keine
/// neue. `amountCents` ist PFLICHT: das Terminal weist einen Void ohne
/// Betrag mit `400 Missing amount` ab (gemessen 27.08.2026); wird deshalb
/// hier verlangt, bevor irgendetwas das Netz berührt.
Future<Response> _handleCancel(_Terminal t, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final daten = body.data!;
  final ziel = _ziel(daten);
  if (ziel == null) return _zielFehler();

  final tid = _tidAus(daten['tid']);
  final transactionId = readString(daten['transactionId'])?.trim() ?? '';
  final amountCents = daten['amountCents'];
  final currency = readString(daten['currency'])?.trim();
  final language = readString(daten['language'])?.trim();
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  if (!_transactionId.hasMatch(transactionId)) {
    return failJson(errorBadRequest, 'Es fehlt die Transaktions-ID.');
  }
  if (amountCents is! int || amountCents <= 0 || amountCents > 100000000) {
    return failJson(errorBadRequest, 'Es fehlt der Betrag (amountCents > 0).');
  }
  if (currency != null && !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
    return failJson(errorBadRequest, 'Währung bitte als ISO-Code (EUR).');
  }
  if (language != null && !RegExp(r'^(DE|IT|SI)$').hasMatch(language)) {
    return failJson(errorBadRequest, 'Sprache: DE, IT oder SI.');
  }

  return t.lang(
    request,
    ziel,
    tid: tid,
    art: LangerAufruf.aufhebung,
    aufruf: (host, port) => t.hps.cancel(
      host: host,
      port: port,
      tid: tid,
      transactionId: transactionId,
      amountCents: amountCents,
      currency: currency ?? 'EUR',
      language: language,
    ),
  );
}

Future<Response> _mitTransaktion(
  _Terminal t,
  Request request,
  Future<Object?> Function(String host, int port, String tid, String txId)
  aufruf,
) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final ziel = _ziel(body.data!);
  if (ziel == null) return _zielFehler();
  final tid = _tidAus(body.data!['tid']);
  final txId = readString(body.data!['transactionId'])?.trim() ?? '';
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  if (!_transactionId.hasMatch(txId)) {
    return failJson(errorBadRequest, 'Es fehlt die Transaktions-ID.');
  }
  return t.ausfuehren(
    request,
    ziel,
    tid: tid,
    aufruf: (host, port) => aufruf(host, port, tid, txId),
  );
}

/// `POST /v1/terminal/discover` `{}` — sucht Hobex-Terminals im Kassen-Netz
/// (Port-8080-Scan wie bei den Druckern, danach fragt `GET /api/terminals`
/// nach). Liefert Treffer samt TIDs und die abgesuchten Netze.
Future<Response> _handleDiscover(
  _Terminal t,
  Future<TerminalDiscoveryResult> Function(HpsBridge, AgentContext) suche,
  Request request,
) async {
  final body = await readJsonBody(request, allowEmpty: true);
  if (body.error != null) return body.error!;
  // Die Suche fragt jedes Terminal im Netz – nie neben einer Zahlung.
  if (t.sperrtBei(request) && t.belegung.irgendeins) return t.besetzt();
  final ergebnis = await suche(t.hps, t.ctx);
  return okJson(ergebnis.toJson());
}

/// `POST /v1/terminal/locate` `{tid}` — sucht das Terminal dieser TID im Netz
/// (Suche, dann Diagnose je Treffer) und merkt sich die eine bestätigte
/// Adresse. Antwort `{tid, host, port, relocated, from?}`; ohne eindeutigen
/// Treffer `device_not_found`, während eines langen Aufrufs `terminal_busy`.
Future<Response> _handleLocate(_Terminal t, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final tid = _tidAus(body.data!['tid']);
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  if (t.belegung.irgendeins) return t.besetzt();
  final fund = await t.wiederfinder?.suche(tid);
  if (fund == null) {
    return failJson(
      errorDeviceNotFound,
      'Das Terminal mit dieser TID ist im Netz nicht eindeutig zu finden.',
    );
  }
  return okJson(<String, Object?>{
    'tid': fund.tid,
    'host': fund.host,
    'port': fund.port,
    'relocated': fund.umgezogen,
    if (fund.umgezogen) 'from': fund.vorher,
  });
}
