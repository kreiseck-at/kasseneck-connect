import 'package:shelf/shelf.dart';

import '../config/model.dart';
import 'auth.dart';
import 'context.dart';
import 'responses.dart';

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
