import 'dart:io';

/// Umgebungsvariable, die den Tests mit echtem `openssl` ein anderes Programm
/// vorgibt — etwa OpenSSL aus Homebrew statt LibreSSL am Mac:
/// `KASSENECK_TEST_OPENSSL=/opt/homebrew/bin/openssl dart test`. Die
/// Schreibweise der Linux-CI (OpenSSL 3.0, `CN = …`) zeigt am Mac `openssl@1.1`.
const String testOpensslVariable = 'KASSENECK_TEST_OPENSSL';

/// Das vorgegebene Programm aus [testOpensslVariable]; `null` ohne Vorgabe.
String? get vorgegebenesOpenssl {
  final wert = Platform.environment[testOpensslVariable];
  return wert == null || wert.isEmpty ? null : wert;
}

/// Das `openssl` der Tests mit echtem openssl: die Vorgabe, sonst
/// `/usr/bin/openssl` (am Mac LibreSSL, so wie beim Kunden).
String get testOpenssl => vorgegebenesOpenssl ?? '/usr/bin/openssl';

/// Grund zum Überspringen, wenn es [testOpenssl] nicht gibt. Eine Vorgabe
/// wird nie übersprungen: fehlt das Programm, scheitert der Test laut, statt
/// still nichts zu prüfen.
String? get ohneTestOpenssl =>
    vorgegebenesOpenssl != null || File(testOpenssl).existsSync()
    ? null
    : 'kein $testOpenssl';
