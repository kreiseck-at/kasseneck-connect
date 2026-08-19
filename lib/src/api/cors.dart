import 'dart:io';

import 'package:shelf/shelf.dart';

import 'auth.dart';
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

/// Umgebungsvariable, die die Entwicklungsherkünfte freischaltet.
const String devOriginsEnvVar = 'KASSENECK_CONNECT_DEV';

/// Methoden, die die lokale API kennt.
const String allowedMethods = 'GET, POST, PUT, DELETE, OPTIONS';

/// Kopfzeilen, die die Kasse mitschicken darf.
const String allowedHeaders = 'Content-Type, Authorization';

/// Prüft eine Herkunft gegen die Allowlist.
///
/// Die Entwicklungsherkünfte (`http://localhost:<port>`,
/// `http://127.0.0.1:<port>`) sind **standardmäßig gesperrt**: auf einem
/// Kundenrechner könnte sonst jede beliebige lokale Webseite drucken. Frei
/// schaltet sie `allowDevOrigins` in der `config.json` oder
/// `KASSENECK_CONNECT_DEV=1`.
bool isAllowedOrigin(String origin, {bool allowDev = false}) {
  if (allowedOrigins.contains(origin)) return true;
  return allowDev && _localhostOrigin.hasMatch(origin);
}

/// `Vary: Origin` gehört auch an abgelehnte Antworten — sonst legt ein Cache
/// die 403 für eine erlaubte Herkunft ab.
const Map<String, Object> _varyOrigin = <String, Object>{'vary': 'Origin'};

/// Routen, die ohne Origin-Kopfzeile und ohne Token erreichbar sind.
///
/// Ohne Origin ruft kein Browser an, sondern ein Werkzeug (curl, `doctor`).
/// Dort ist nur die Diagnose plus die Kopplung sinnvoll — alles andere wäre
/// eine Hintertür an der Allowlist vorbei.
bool isPublicRoute(String method, String path) {
  final normalized = normalizeRoutePath(path);
  return (method == 'GET' && normalized == '/v1/status') ||
      (method == 'POST' && normalized == '/v1/pair');
}

/// Schneidet einen abschließenden Schrägstrich ab, damit `/v1/status` und
/// `/v1/status/` als dieselbe Route gelten.
String normalizeRoutePath(String path) => path.endsWith('/') && path.length > 1
    ? path.substring(0, path.length - 1)
    : path;

/// Origin-Prüfung, Preflight und die CORS-Kopfzeilen der Antwort.
///
/// Der Browser darf eine private Adresse (127.0.0.1) nur ansprechen, wenn der
/// Preflight `Access-Control-Allow-Private-Network: true` trägt (Private
/// Network Access) — deshalb steht die Zeile an jedem erlaubten Preflight.
Middleware corsMiddleware({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final devByEnv = env[devOriginsEnvVar] == '1';

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
            headers: _varyOrigin,
          );
        }
        return innerHandler(request);
      }

      final allowDev = devByEnv || configOf(request).allowDevOrigins;
      if (!isAllowedOrigin(origin, allowDev: allowDev)) {
        return failJson(
          errorOriginForbidden,
          'Diese Herkunft darf den Agenten nicht ansprechen.',
          status: 403,
          detail: origin,
          headers: _varyOrigin,
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
