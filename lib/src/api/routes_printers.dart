import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/model.dart';
import '../printers/discovery.dart';
import '../printers/driver.dart';
import '../printers/erkennung.dart';
import '../printers/funde.dart';
import '../printers/queue.dart';
import '../printers/registry.dart';
import '../printers/statustakt.dart';
import '../printers/wiederfinden.dart';
import 'context.dart';
import 'responses.dart';
import 'routes_print.dart';

/// Erlaubte Form einer Drucker-ID im Pfad.
final RegExp _printerId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Pfad-ID, mit der die Kasse „leg einen neuen Drucker an" meint.
///
/// Ein REST-PUT braucht eine ID im Pfad, die Kasse hat aber noch keine — sie
/// schickt darum `neu`. Ohne diese Ausnahme landete ein Drucker mit der ID
/// `neu` in der Konfiguration, und jeder weitere Drucker überschriebe ihn.
const String newPrinterPathId = 'neu';

/// Meldet die Drucker-Endpunkte am Router an.
///
/// ```dart
/// buildHandler(ctx, extraRoutes: [
///   printerRoutes(registry: registry, queue: queue),
/// ]);
/// ```
/// Alle Pfade sind damit automatisch token- und herkunftsgeschützt.
RouteRegistrar printerRoutes({
  required PrinterRegistry registry,
  required PrintQueue queue,
  PrinterDiscovery? discovery,
  Kennungspflege? kennung,
  FundGedaechtnis? funde,
  DruckerStatusDienst? status,
  DruckerWiederfinder? wiederfinder,
}) {
  return (Router router, AgentContext ctx) {
    final search = discovery ?? PrinterDiscovery(log: ctx.log);

    router
      ..get('/v1/printers', (Request r) => handleListPrinters(registry, r))
      ..post(
        '/v1/printers/discover',
        (Request r) =>
            handleDiscoverPrinters(search, r, funde: funde, kennung: kennung),
      )
      ..put(
        '/v1/printers',
        (Request r) => handlePutPrinter(registry, r, null, kennung: kennung),
      )
      ..put(
        '/v1/printers/<id>',
        (Request r, String id) =>
            handlePutPrinter(registry, r, id, kennung: kennung),
      )
      ..delete(
        '/v1/printers/<id>',
        (Request r, String id) => handleDeletePrinter(registry, queue, r, id),
      )
      ..post(
        '/v1/printers/<id>/test',
        (Request r, String id) => handleTestPrint(queue, r, id),
      )
      ..post('/v1/print', (Request r) => handlePrint(queue, r));
    if (status != null) {
      router.post(
        '/v1/printers/<id>/status',
        (Request r, String id) => handlePrinterStatus(status, id),
      );
    }
    if (wiederfinder != null) {
      router.post(
        '/v1/printers/<id>/locate',
        (Request r, String id) => handleLocatePrinter(wiederfinder, id),
      );
    }
  };
}

/// `GET /v1/printers` — konfigurierte Drucker samt Zustand.
///
/// Standardmäßig werden die Geräte kurz angefragt (`?probe=0` schaltet das
/// ab): die Einstellungsseite der Kasse soll den wirklichen Zustand zeigen und
/// nicht den von vorgestern.
Future<Response> handleListPrinters(
  PrinterRegistry registry,
  Request request,
) async {
  final probe = request.requestedUri.queryParameters['probe'];
  final wanted = probe != '0' && probe != 'false';
  return okJson(<String, Object?>{
    'printers': await registry.summaries(probe: wanted),
  });
}

/// `PUT /v1/printers` bzw. `PUT /v1/printers/{id}` — anlegen oder ändern.
///
/// Ohne ID im Pfad — und ebenso bei [newPrinterPathId] — vergibt der Agent
/// eine; die Kasse denkt sich keine IDs aus. Zwei solche Anfragen ergeben zwei
/// Drucker, es sei denn, beide zeigen auf dieselbe Adresse: dann wird der
/// vorhandene Eintrag aktualisiert (siehe [PrinterRegistry.upsert]).
Future<Response> handlePutPrinter(
  PrinterRegistry registry,
  Request request,
  String? id, {
  Kennungspflege? kennung,
}) async {
  final wanted = (id == null || id.isEmpty || id == newPrinterPathId) ? '' : id;
  if (wanted.isNotEmpty && !_printerId.hasMatch(wanted)) {
    return failJson(errorBadRequest, 'Die Drucker-ID ist unbrauchbar.');
  }

  final body = await readJsonBody(request);
  final error = body.error;
  if (error != null) return error;

  final parsed = parsePrinterInput(body.data!, id: wanted);
  if (parsed.problem != null) {
    return failJson(errorBadRequest, parsed.problem!);
  }

  final saved = await registry.upsert(parsed.printer!);
  // Die Kennung ermittelt Connect selbst (mDNS, GS I, ARP) und im Hintergrund:
  // die Antwort soll nicht auf den Drucker warten. Nie vor einem Bon – fehlt
  // sie, holen sie die nächste Druckersuche oder eine Statusabfrage nach.
  if (!saved.hatKennung) unawaited(kennung?.nachAnlegen(saved.id));
  return okJson(<String, Object?>{
    'printer': <String, Object?>{
      ...saved.toApiJson(),
      'state': registry.stateOf(saved.id).wireName,
    },
  });
}

/// `DELETE /v1/printers/{id}`.
///
/// Mit dem Drucker verschwinden auch seine Warteschlange und die gemerkten
/// Auftrags-IDs — sonst wüchsen beide Tabellen mit jedem entfernten Gerät.
Future<Response> handleDeletePrinter(
  PrinterRegistry registry,
  PrintQueue queue,
  Request request,
  String id,
) async {
  if (!await registry.remove(id)) {
    return failJson(errorPrinterUnknown, 'Diesen Drucker gibt es nicht.');
  }
  queue.forgetPrinter(id);
  return okJson(<String, Object?>{'id': id});
}

/// `POST /v1/printers/{id}/status` — fragt Papier, Deckel und Erreichbarkeit
/// sofort ab (über die Warteschlange, nie neben einem Bon) und liefert den
/// Drucker wie `GET /v1/printers`.
Future<Response> handlePrinterStatus(
  DruckerStatusDienst status,
  String id,
) async {
  final drucker = await status.jetzt(id);
  if (drucker == null) {
    return failJson(errorPrinterUnknown, 'Diesen Drucker gibt es nicht.');
  }
  return okJson(<String, Object?>{'printer': drucker});
}

/// `POST /v1/printers/{id}/locate` — sucht den Drucker gründlich unter einer
/// neuen Adresse und übernimmt sie, wenn es genau einen bestätigten Treffer
/// gibt. Antwort: `{relocated: true, from, to, printer}`; ohne eindeutigen
/// Treffer `device_not_found`.
Future<Response> handleLocatePrinter(
  DruckerWiederfinder wiederfinder,
  String id,
) async {
  final vorher = await wiederfinder.registry.find(id);
  if (vorher == null) {
    return failJson(errorPrinterUnknown, 'Diesen Drucker gibt es nicht.');
  }
  if (!vorher.hatKennung) {
    return failJson(
      errorDeviceNotFound,
      'Der Drucker hat noch keine Kennung – Connect kann ihn nicht suchen.',
    );
  }
  final neu = await wiederfinder.gruendlich(id, erzwingen: true);
  if (neu == null || neu.host == vorher.host) {
    return failJson(
      errorDeviceNotFound,
      'Der Drucker ist unter keiner anderen Adresse eindeutig zu finden.',
    );
  }
  return okJson(<String, Object?>{
    'relocated': true,
    'from': '${vorher.host}:${vorher.port}',
    'to': '${neu.host}:${neu.port}',
    'printer': wiederfinder.registry.zusammenfassung(neu),
  });
}

/// `POST /v1/printers/discover` — `{scan?: bool}`.
Future<Response> handleDiscoverPrinters(
  PrinterDiscovery discovery,
  Request request, {
  FundGedaechtnis? funde,
  Kennungspflege? kennung,
}) async {
  final body = await readJsonBody(request, allowEmpty: true);
  final error = body.error;
  if (error != null) return error;

  final found = await discovery.discover(scan: body.data!['scan'] == true);
  funde?.merke(found.printers);
  // Eine Suche ist ein Anlass, die eingerichteten Drucker ohne gelesenes
  // Modell zu erkennen – im Hintergrund, über ihre Warteschlangen.
  if (kennung != null) unawaited(kennung.nachSuche());
  // `scanned` sagt der Kasse, wo gesucht wurde („Suche in 192.168.0.0/24 …")
  // — und beim Kunden, warum nichts gefunden wurde: steht dort nur das Netz
  // einer virtuellen Maschine, hängt der Drucker woanders.
  return okJson(found.toJson());
}

/// Ergebnis der Eingabeprüfung: entweder ein Drucker oder ein Klartextgrund.
class PrinterInput {
  PrinterInput.valid(this.printer) : problem = null;

  const PrinterInput.invalid(this.problem) : printer = null;

  final PrinterConfig? printer;
  final String? problem;
}

/// Prüft den Rumpf eines `PUT /v1/printers`.
///
/// Bewusst streng: `PrinterKind.fromWireName` macht aus jedem Unsinn stillheim
/// `tcp9100`, was beim Laden einer alten Datei richtig ist — aber nicht, wenn
/// die Kasse gerade `epos` gemeint und sich vertippt hat.
PrinterInput parsePrinterInput(
  Map<String, Object?> data, {
  required String id,
}) {
  final kindName = data['kind'];
  PrinterKind? kind;
  for (final candidate in PrinterKind.values) {
    if (candidate.wireName == kindName) kind = candidate;
  }
  if (kind == null) {
    return const PrinterInput.invalid(
      'Unbekannte Anbindung (kind): erlaubt sind tcp9100 und epos.',
    );
  }

  final host = _text(data['host']);
  if (host == null || host.contains(RegExp(r'\s'))) {
    return const PrinterInput.invalid(
      'Es fehlt eine brauchbare Adresse (host).',
    );
  }

  final int port;
  if (data.containsKey('port') && data['port'] != null) {
    final value = readInt(data['port']);
    if (value == null || value < 1 || value > 65535) {
      return const PrinterInput.invalid(
        'Der Port muss zwischen 1 und 65535 liegen.',
      );
    }
    port = value;
  } else {
    port = kind.defaultPort;
  }

  final devid = _text(data['devid']);

  return PrinterInput.valid(
    PrinterConfig(
      id: id,
      // Ohne Namen steht die Adresse in der Liste — besser als eine leere Zeile.
      name: _text(data['name']) ?? host,
      kind: kind,
      host: host,
      port: port,
      devid: kind == PrinterKind.epos ? devid : null,
    ),
  );
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
