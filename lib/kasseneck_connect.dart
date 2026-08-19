/// Kasseneck Connect — lokaler Agent der Browser-Kasse.
///
/// Öffentliche Bausteine dieser Etappe: Kommandozeile, Konfiguration, Log,
/// lokale API (CORS/PNA, Token, Status), Kopplung und der Agent selbst.
library;

export 'src/agent.dart';
export 'src/api/auth.dart';
export 'src/api/context.dart';
export 'src/api/cors.dart';
export 'src/api/responses.dart';
export 'src/api/routes_pair.dart';
export 'src/api/routes_status.dart';
export 'src/api/server.dart';
export 'src/cli.dart';
export 'src/config/model.dart';
export 'src/config/paths.dart';
export 'src/config/store.dart';
export 'src/log/logger.dart';
export 'src/pairing/pairing.dart';
export 'src/version.dart';
