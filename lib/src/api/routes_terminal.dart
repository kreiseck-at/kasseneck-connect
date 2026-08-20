import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/model.dart';
import '../terminal/discovery.dart';
import '../terminal/hps.dart';
import 'context.dart';
import 'responses.dart';

/// Erlaubte Form eines Hosts (IP oder Hostname) — keine Pfade, keine Ports,
/// keine Leerzeichen: der Wert landet in einer URL.
final RegExp _host = RegExp(r'^[A-Za-z0-9.\-]{1,253}$');

/// TID laut Spec: Ziffern (ohne führende Null gepflegt, das prüft die Kasse).
final RegExp _tid = RegExp(r'^\d{1,16}$');

/// Transaktions-ID: numerisch, höchstens 18 Stellen (Spec).
final RegExp _transactionId = RegExp(r'^\d{1,18}$');

/// Meldet die Terminal-Endpunkte (Hobex HPS) am Router an.
///
/// Alle Pfade sind token- und herkunftsgeschützt — wer drucken darf, darf
/// auch das Terminal ansprechen; einen eigenen Vertrauenskreis gibt es nicht.
/// Die Brücke reicht die HPS-Antwort unverändert als `hps` durch.
RouteRegistrar terminalRoutes({
  HpsBridge? bridge,
  // Nur für Tests: die echte Suche scannt das Netz des Rechners.
  Future<TerminalDiscoveryResult> Function(HpsBridge, AgentContext)? discover,
}) {
  return (Router router, AgentContext ctx) {
    final hps = bridge ?? HpsBridge(log: ctx.log);
    final suche =
        discover ??
        (HpsBridge h, AgentContext c) =>
            discoverTerminals(bridge: h, log: c.log);

    router
      ..post('/v1/terminal/test', (Request r) => _handleTest(hps, r))
      ..post(
        '/v1/terminal/discover',
        (Request r) => _handleDiscover(hps, ctx, suche, r),
      )
      ..post('/v1/terminal/diagnosis', (Request r) => _handleDiagnosis(hps, r))
      ..post('/v1/terminal/payment', (Request r) => _handlePayment(hps, r))
      ..post('/v1/terminal/status', (Request r) => _handleStatus(hps, r))
      ..post('/v1/terminal/abort', (Request r) => _handleAbort(hps, r));
  };
}

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

Future<Response> _mitHps(Future<Object?> Function() aufruf) async {
  try {
    final daten = await aufruf();
    return okJson(<String, Object?>{'hps': daten});
  } on HpsWegFehler catch (e) {
    return failJson(e.code, e.message);
  }
}

/// `POST /v1/terminal/test` `{host, port?, tid?}` — Erreichbarkeit.
///
/// Ohne TID die nebenwirkungsfreie Probe (`/api/terminals/0/diagnosis`,
/// Antwort „Invalid TID“ beweist das HPS); mit TID die echte Diagnose samt
/// Gerätestatus. Antwortet die Gegenstelle zwar, aber nicht im HPS-Format,
/// ist es kein Terminal (`terminal_error`).
Future<Response> _handleTest(HpsBridge hps, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final ziel = _ziel(body.data!);
  if (ziel == null) return _zielFehler();
  final tid = readString(body.data!['tid'])?.trim() ?? '';
  return _mitHps(() async {
    final antwort = tid.isEmpty
        ? await hps.probe(host: ziel.$1, port: ziel.$2)
        : await hps.diagnosis(host: ziel.$1, port: ziel.$2, tid: tid);
    if (!siehtNachHpsAus(antwort)) {
      throw HpsWegFehler(
        errorTerminalError,
        'Unter ${ziel.$1}:${ziel.$2} antwortet etwas — aber kein '
        'Hobex-Terminal.',
      );
    }
    return antwort;
  });
}

/// `POST /v1/terminal/diagnosis` `{host, port?, tid}`.
Future<Response> _handleDiagnosis(HpsBridge hps, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final ziel = _ziel(body.data!);
  if (ziel == null) return _zielFehler();
  final tid = readString(body.data!['tid'])?.trim() ?? '';
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  return _mitHps(() => hps.diagnosis(host: ziel.$1, port: ziel.$2, tid: tid));
}

/// `POST /v1/terminal/payment`
/// `{host, port?, tid, amountCents, transactionId, tipCents?, reference?,
///   currency?, language?}` — blockiert bis zum Ende des Kartenflows.
///
/// `transactionId` MUSS die Kasse vergeben und sich merken: sie ist der
/// einzige Schlüssel für Status-Abfrage und Storno, wenn der lange Aufruf
/// reißt. Eine Ablehnung kommt als `ok:true` mit `responseCode != "0"` im
/// `hps`-Rumpf zurück — abgelehnt ist eine Antwort, kein Transportfehler.
Future<Response> _handlePayment(HpsBridge hps, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final daten = body.data!;
  final ziel = _ziel(daten);
  if (ziel == null) return _zielFehler();

  final tid = readString(daten['tid'])?.trim() ?? '';
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

  return _mitHps(
    () => hps.payment(
      host: ziel.$1,
      port: ziel.$2,
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

/// `POST /v1/terminal/status` `{host, port?, tid, transactionId}`.
Future<Response> _handleStatus(HpsBridge hps, Request request) =>
    _mitTransaktion(hps, request, (hps, ziel, tid, txId) {
      return hps.status(
        host: ziel.$1,
        port: ziel.$2,
        tid: tid,
        transactionId: txId,
      );
    });

/// `POST /v1/terminal/abort` `{host, port?, tid, transactionId}`.
Future<Response> _handleAbort(HpsBridge hps, Request request) =>
    _mitTransaktion(hps, request, (hps, ziel, tid, txId) {
      return hps.abort(
        host: ziel.$1,
        port: ziel.$2,
        tid: tid,
        transactionId: txId,
      );
    });

Future<Response> _mitTransaktion(
  HpsBridge hps,
  Request request,
  Future<Object?> Function(HpsBridge, (String, int), String, String) aufruf,
) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;
  final ziel = _ziel(body.data!);
  if (ziel == null) return _zielFehler();
  final tid = readString(body.data!['tid'])?.trim() ?? '';
  final txId = readString(body.data!['transactionId'])?.trim() ?? '';
  if (!_tid.hasMatch(tid)) {
    return failJson(errorBadRequest, 'Es fehlt die Terminal-ID (tid).');
  }
  if (!_transactionId.hasMatch(txId)) {
    return failJson(errorBadRequest, 'Es fehlt die Transaktions-ID.');
  }
  return _mitHps(() => aufruf(hps, ziel, tid, txId));
}

/// `POST /v1/terminal/discover` `{}` — sucht Hobex-Terminals im Kassen-Netz
/// (Port-8080-Scan wie bei den Druckern, danach fragt `GET /api/terminals`
/// nach). Liefert Treffer samt TIDs und die abgesuchten Netze.
Future<Response> _handleDiscover(
  HpsBridge hps,
  AgentContext ctx,
  Future<TerminalDiscoveryResult> Function(HpsBridge, AgentContext) suche,
  Request request,
) async {
  final body = await readJsonBody(request, allowEmpty: true);
  if (body.error != null) return body.error!;
  final ergebnis = await suche(hps, ctx);
  return okJson(ergebnis.toJson());
}
