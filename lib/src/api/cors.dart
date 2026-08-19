import 'package:shelf/shelf.dart';

import 'responses.dart';

/// Herkünfte, die den Agenten ansprechen dürfen (exakter Vergleich).
const List<String> allowedOrigins = <String>[
  'https://kasse.kasseneck.at',
  'https://kasseneck-kasse.web.app',
  'https://kasseneck-kasse.firebaseapp.com',
];

/// Entwicklung: `http://localhost:<port>` und `http://127.0.0.1:<port>`.
final RegExp _localhostOrigin = RegExp(
  r'^http://(localhost|127\.0\.0\.1)(:\d{1,5})?$',
);

/// Methoden, die die lokale API kennt.
const String allowedMethods = 'GET, POST, PUT, DELETE, OPTIONS';

/// Kopfzeilen, die die Kasse mitschicken darf.
const String allowedHeaders = 'Content-Type, Authorization';

/// Prüft eine Herkunft gegen die Allowlist.
bool isAllowedOrigin(String origin) =>
    allowedOrigins.contains(origin) || _localhostOrigin.hasMatch(origin);

/// Routen, die ohne Origin-Kopfzeile und ohne Token erreichbar sind.
///
/// Ohne Origin ruft kein Browser an, sondern ein Werkzeug (curl, `doctor`).
/// Dort ist nur die Diagnose plus die Kopplung sinnvoll — alles andere wäre
/// eine Hintertür an der Allowlist vorbei.
bool isPublicRoute(String method, String path) {
  final normalized = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  return (method == 'GET' && normalized == '/v1/status') ||
      (method == 'POST' && normalized == '/v1/pair');
}

/// Origin-Prüfung, Preflight und die CORS-Kopfzeilen der Antwort.
///
/// Der Browser darf eine private Adresse (127.0.0.1) nur ansprechen, wenn der
/// Preflight `Access-Control-Allow-Private-Network: true` trägt (Private
/// Network Access) — deshalb steht die Zeile an jedem erlaubten Preflight.
Middleware corsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      final origin = request.headers['origin'];
      final method = request.method.toUpperCase();
      final path = request.requestedUri.path;

      if (origin == null) {
        if (!isPublicRoute(method, path)) {
          return failJson(
            errorOriginForbidden,
            'Ohne Herkunft ist nur der Status abrufbar.',
            status: 403,
          );
        }
        return innerHandler(request);
      }

      if (!isAllowedOrigin(origin)) {
        return failJson(
          errorOriginForbidden,
          'Diese Herkunft darf den Agenten nicht ansprechen.',
          status: 403,
          detail: origin,
        );
      }

      final corsHeaders = <String, Object>{
        'access-control-allow-origin': origin,
        'vary': 'Origin',
      };

      if (method == 'OPTIONS') {
        return Response(
          204,
          headers: <String, Object>{
            ...corsHeaders,
            'access-control-allow-methods': allowedMethods,
            'access-control-allow-headers': allowedHeaders,
            'access-control-allow-private-network': 'true',
            'access-control-max-age': '600',
          },
        );
      }

      final response = await innerHandler(request);
      return response.change(headers: corsHeaders);
    };
  };
}
