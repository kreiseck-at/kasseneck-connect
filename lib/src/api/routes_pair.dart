import 'package:shelf/shelf.dart';

import '../config/model.dart';
import 'auth.dart';
import 'context.dart';
import 'responses.dart';

/// Mindestabstand zwischen zwei Kopplungsanforderungen (`POST /v1/pair/request`).
const Duration pairRequestMinInterval = Duration(seconds: 10);

/// `POST /v1/pair/request` — die Kopplung aus der Kasse heraus anstoßen.
///
/// Der Agent erzeugt einen frischen Code (derselbe Weg wie beim Agentenstart
/// und bei `kasseneck-connect pair`) und öffnet damit die Kopplungsseite im
/// Standardbrowser des Rechners. `KASSENECK_CONNECT_NO_BROWSER=1` unterdrückt
/// das Öffnen; der Code steht dann wie gehabt in der Konfiguration.
///
/// **Ohne Token erreichbar — genau darum geht es:** gebraucht wird der
/// Endpunkt, wenn die Kasse noch **nicht** gekoppelt ist. Sicherheitlich kann
/// ein Aufruf nichts weiter, als auf **demselben Rechner** ein Browserfenster
/// aufgehen zu lassen: der Code geht nie über die API hinaus — die Antwort ist
/// bloß `{ok: true}` —, sondern steht allein in dem lokal geöffneten Fenster.
/// Wer den Endpunkt aufruft, ohne an diesem Rechner zu sitzen, sieht ihn nicht
/// und kommt damit auch keinen Schritt weiter. Bleibt der Belästigungsfall
/// (Fenster über Fenster), und dagegen steht [pairRequestMinInterval].
///
/// Eine **bereits gekoppelte** Kasse darf ebenfalls anstoßen: ein zweites
/// Browserprofil oder ein zweiter Rechner braucht seinen eigenen Token, und
/// die vorhandenen Tokens bleiben davon unberührt.
Future<Response> handlePairRequest(AgentContext ctx, Request request) async {
  final now = ctx.clock();
  final last = ctx.lastPairRequestAt;
  if (last != null && now.difference(last) < pairRequestMinInterval) {
    return failJson(
      errorPairRequestThrottled,
      'Bitte kurz warten und erneut versuchen.',
    );
  }
  ctx.lastPairRequestAt = now;

  final code = await ctx.pairing.newCode();
  ctx.log.info('Kopplung aus der Kasse angestoßen — neuer Code erzeugt.');
  await ctx.pairing.openPairingPage(
    code,
    ctx.port,
    environment: ctx.environment,
  );
  return okJson(const <String, Object?>{});
}

/// `POST /v1/pair/direct` — Kopplung in einem Schritt, direkt aus der Kasse.
///
/// Gibt den Token unmittelbar in der Antwort zurück; die Kasse bleibt dabei
/// auf ihrer Einstellungsseite, ohne Browsersprung und ohne Code-Eingabe.
///
/// Das ist gleichwertig zum Code-Weg: lesen kann die Antwort nur eine Seite,
/// deren Herkunft die **serverseitige** Allowlist passiert hat (fremde Seiten
/// bekommen dort 403), und den Agenten erreicht ohnehin nur, wer an diesem
/// Rechner sitzt (127.0.0.1). Ein lokaler Prozess wiederum kann sich heute
/// schon koppeln (`/v1/pair/request` anstoßen und den Code aus der
/// Konfigurationsdatei lesen) — der Endpunkt öffnet also keine neue Tür.
/// Aufrufe **ohne** Origin-Kopfzeile weisen wir trotzdem ab: Werkzeuge haben
/// mit `kasseneck-connect pair` ihren eigenen, nachvollziehbaren Weg.
///
/// Die Drossel teilt sich der Endpunkt mit `POST /v1/pair/request`, damit
/// niemand die beiden im Wechsel hämmert.
Future<Response> handlePairDirect(AgentContext ctx, Request request) async {
  if (request.headers['origin'] == null) {
    return failJson(
      errorOriginForbidden,
      'Direkte Kopplung geht nur aus dem Browser — am Rechner bitte '
      '`kasseneck-connect pair` verwenden.',
      status: 403,
    );
  }

  final now = ctx.clock();
  final last = ctx.lastPairRequestAt;
  if (last != null && now.difference(last) < pairRequestMinInterval) {
    return failJson(
      errorPairRequestThrottled,
      'Bitte kurz warten und erneut versuchen.',
    );
  }
  ctx.lastPairRequestAt = now;

  final token = await ctx.pairing.issueToken();
  ctx.log.info('Kasse direkt gekoppelt (Ein-Klick aus der Kasse).');
  return okJson(<String, Object?>{'token': token});
}

/// `POST /v1/pair` `{code}` — Code gegen Token tauschen.
///
/// Diese Route ist absichtlich ohne Token erreichbar; geschützt ist sie durch
/// den kurzlebigen Code, die Fehlversuchssperre und die Origin-Allowlist.
Future<Response> handlePair(AgentContext ctx, Request request) async {
  final body = await readJsonBody(request);
  if (body.error != null) return body.error!;

  final code = readString(body.data!['code'])?.trim();
  if (code == null || code.isEmpty) {
    return failJson(errorBadRequest, 'Es fehlt der Kopplungscode.');
  }

  final failure = await ctx.pairing.verify(code);
  if (failure != null) {
    return failJson(failure.errorCode, failure.message);
  }

  final token = await ctx.pairing.issueToken();
  return okJson(<String, Object?>{'token': token});
}

/// `DELETE /v1/pair` — den mitgeschickten Token widerrufen.
///
/// Andere Tokens (weitere Browserprofile/Geräte) bleiben bestehen.
Future<Response> handleUnpair(AgentContext ctx, Request request) async {
  final token = tokenOf(request);
  if (token == null) {
    return failJson(
      errorUnauthorized,
      'Kasse ist nicht gekoppelt.',
      status: 401,
    );
  }
  final removed = await ctx.pairing.revokeToken(token);
  return okJson(<String, Object?>{'revoked': removed});
}
