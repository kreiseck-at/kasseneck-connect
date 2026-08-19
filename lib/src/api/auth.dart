import 'package:shelf/shelf.dart';

import '../config/model.dart';
import '../config/store.dart';
import '../pairing/pairing.dart';
import 'cors.dart';
import 'responses.dart';
import 'routes_events.dart';

/// Schlüssel im `Request.context`: gültiger Token vorhanden (`bool`).
const String contextAuthenticated = 'connect.authenticated';

/// Schlüssel im `Request.context`: die für diese Anfrage gelesene Konfiguration.
const String contextConfig = 'connect.config';

/// Schlüssel im `Request.context`: der mitgeschickte Token im Klartext.
const String contextToken = 'connect.token';

/// Name des Query-Parameters, unter dem allein `GET /v1/events` den Token
/// annimmt.
const String tokenQueryParameter = 'token';

/// Liest den Token aus `Authorization: Bearer <token>`.
String? bearerToken(String? header) {
  if (header == null) return null;
  final trimmed = header.trim();
  if (trimmed.length < 8) return null;
  if (trimmed.substring(0, 7).toLowerCase() != 'bearer ') return null;
  final token = trimmed.substring(7).trim();
  return token.isEmpty ? null : token;
}

/// Token dieser Anfrage: Kopfzeile, ersatzweise `?token=` an `GET /v1/events`.
///
/// Der Browser kann bei `new WebSocket(url)` **keine** Kopfzeilen setzen — es
/// gibt keine Entsprechung zu `fetch(…, {headers})`. Damit die Kasse den
/// Ereignisstrom trotzdem authentifiziert öffnen kann, zählt der Token dort
/// auch als Query-Parameter. Bewusst **nur** an dieser einen Route: an allen
/// anderen bliebe eine Adresse mit Geheimnis in Verläufen und Protokollen
/// liegen. Der Agent selbst schreibt keine Anfrageadressen ins Log, und die
/// Verbindung geht nicht über das Netz hinaus (127.0.0.1).
String? requestToken(Request request) {
  final header = bearerToken(request.headers['authorization']);
  if (header != null) return header;

  if (request.method.toUpperCase() != 'GET') return null;
  if (normalizeRoutePath(request.requestedUri.path) != eventsPath) return null;
  final query = request.requestedUri.queryParameters[tokenQueryParameter];
  if (query == null) return null;
  final token = query.trim();
  return token.isEmpty ? null : token;
}

/// Liest die Konfiguration **einmal je Anfrage** und legt sie in den
/// `Request.context`.
///
/// Steht ganz vorn in der Kette, weil schon die Origin-Prüfung wissen muss, ob
/// Entwicklungsherkünfte freigeschaltet sind — und danach die Token-Prüfung und
/// die Routen dieselbe Momentaufnahme sehen sollen.
Middleware configLoader(ConfigStore store) {
  return (Handler innerHandler) {
    return (Request request) async {
      final config = await store.load();
      return innerHandler(
        request.change(context: <String, Object?>{contextConfig: config}),
      );
    };
  };
}

/// Token-Pflicht für alles außer `GET /v1/status` und `POST /v1/pair`.
///
/// Verglichen wird nur der SHA-256-Hash gegen `tokenHashes` — der Agent kennt
/// den Klartext-Token nur für die Dauer der Anfrage. Ein Zeitangriff auf den
/// Vergleich läuft ins Leere: verglichen werden Hashes, nicht Geheimnisse.
///
/// `GET /v1/status` läuft auch ohne Token durch; die Route sieht am
/// [contextAuthenticated]-Flag, ob sie die Kurz- oder die Langform liefert.
Middleware tokenAuth() {
  return (Handler innerHandler) {
    return (Request request) async {
      final config = configOf(request);
      final token = requestToken(request);
      final authenticated =
          token != null && config.tokenHashes.contains(hashToken(token));

      if (!authenticated &&
          !isPublicRoute(
            request.method.toUpperCase(),
            request.requestedUri.path,
          )) {
        return failJson(
          errorUnauthorized,
          'Kasse ist nicht gekoppelt.',
          status: 401,
        );
      }

      return innerHandler(
        request.change(
          context: <String, Object?>{
            contextAuthenticated: authenticated,
            if (token != null) contextToken: token,
          },
        ),
      );
    };
  };
}

/// Konfiguration, die die Auth-Schicht für diese Anfrage gelesen hat.
AgentConfig configOf(Request request) =>
    request.context[contextConfig]! as AgentConfig;

/// Ob die Anfrage einen gültigen Token trug.
bool isAuthenticated(Request request) =>
    request.context[contextAuthenticated] == true;

/// Der mitgeschickte Token im Klartext (nur zum Widerrufen nötig).
String? tokenOf(Request request) => request.context[contextToken] as String?;
