import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/model.dart';
import '../printers/discovery.dart';
import '../printers/driver.dart';
import '../printers/queue.dart';
import '../printers/registry.dart';
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
}) {
  return (Router router, AgentContext ctx) {
    final search = discovery ?? PrinterDiscovery(log: ctx.log);

    router
      ..get('/v1/printers', (Request r) => handleListPrinters(registry, r))
      ..post(
        '/v1/printers/discover',
        (Request r) => handleDiscoverPrinters(search, r),
      )
      ..put('/v1/printers', (Request r) => handlePutPrinter(registry, r, null))
      ..put(
        '/v1/printers/<id>',
        (Request r, String id) => handlePutPrinter(registry, r, id),
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
  String? id,
) async {
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
  return okJson(<String, Object?>{
    'printer': <String, Object?>{
      ...saved.toJson(),
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

/// `POST /v1/printers/discover` — `{scan?: bool}`.
Future<Response> handleDiscoverPrinters(
  PrinterDiscovery discovery,
  Request request,
) async {
  final body = await readJsonBody(request, allowEmpty: true);
  final error = body.error;
  if (error != null) return error;

  final found = await discovery.discover(scan: body.data!['scan'] == true);
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
