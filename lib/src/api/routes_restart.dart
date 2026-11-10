import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../betrieb/vorgaenge.dart';
import '../events/bus.dart';
import 'context.dart';
import 'responses.dart';

/// Ein Druck oder eine Zahlung läuft (ab 1.5.0).
const String errorRestartBusy = 'restart_busy';

/// So lange nach der Antwort beendet sich Connect (Spec 1.5: 0,5 s) – die
/// Antwort soll die Kasse noch erreichen.
const Duration neustartVerzug = Duration(milliseconds: 500);

/// `POST /v1/restart` – für den Fernbefehl „Connect neu starten“.
///
/// Nur wo der Autostart einen beendeten Agenten wieder startet (macOS
/// `KeepAlive`, Linux systemd) und Connect auch von dort gestartet wurde;
/// sonst gibt es den Pfad nicht (`not_found`) und `features` nennt `restart`
/// nicht. Während eines Drucks oder einer Zahlung `restart_busy` (409) – immer,
/// auch mit abgeschaltetem `busy_lock`: der Not-Aus gilt der Belegung des
/// Terminals und der Update-Sperre, ein Neustart riss den Vorgang dagegen
/// sicher ab. Beginnt in der halben Sekunde bis zum Beenden doch noch ein
/// Vorgang, wartet Connect dessen Ende ab (höchstens `vorgangHoechstdauer`).
RouteRegistrar restartRoutes() {
  return (Router router, AgentContext ctx) {
    router.post('/v1/restart', (Request request) async {
      final neustart = ctx.neustart;
      if (neustart == null) {
        return failJson(
          errorNotFound,
          'Diesen Pfad gibt es nicht.',
          status: 404,
        );
      }
      final vorgaenge = ctx.vorgaenge;
      if (vorgaenge?.laufen ?? false) {
        return failJson(
          errorRestartBusy,
          'Gerade läuft ein Druck oder eine Zahlung – danach neu starten.',
          status: 409,
        );
      }
      ctx.log.info('Neustart angefordert.');
      ctx.events.publish(eventAgentRestarting, <String, Object?>{
        'reason': 'restart',
      });
      neustartPlanen(neustart: neustart, vorgaenge: vorgaenge);
      return okJson(<String, Object?>{'restarting': true});
    });
  };
}

/// Ruft [neustart] nach [neustartVerzug] – und wartet vorher das Ende
/// laufender [vorgaenge] ab (höchstens `vorgangHoechstdauer`), die in der
/// Zwischenzeit begonnen haben.
void neustartPlanen({
  required Future<void> Function() neustart,
  LaufendeVorgaenge? vorgaenge,
}) {
  Timer(neustartVerzug, () async {
    await vorgaenge?.leer(hoechstens: vorgangHoechstdauer);
    await neustart();
  });
}
