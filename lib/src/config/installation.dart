import 'dart:io';
import 'dart:math';

import '../log/logger.dart';
import 'model.dart' show isInstallationId;
import 'paths.dart';
import 'store.dart';

/// Eine neue Installationskennung: UUID v4 (RFC 9562, Abschnitt 5.4) aus
/// [random].
///
/// Version 4, weil die Kennung nichts über den Rechner verraten soll (keine
/// MAC, keine Zeit wie bei v1) und Zufall für eine Unterscheidung je Rechner
/// und Benutzer reicht.
String neueInstallationId(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  // Versionsfeld (4) im oberen Halbbyte von Byte 6, Variante (10xx) in Byte 8.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Liefert die Installationskennung und legt sie beim ersten Start an.
///
/// Sie steht in der `config.json` und zusätzlich in `installation-id`
/// ([ConfigPaths.installationIdFile]); fehlt sie in der einen, kommt sie aus
/// der anderen zurück. Geschrieben wird nur, was fehlt – in der
/// `config.json` unter der Sperre von [ConfigStore.mutate], die selbst noch
/// einmal nachsieht: starten zwei Prozesse zugleich, gewinnt eine Kennung,
/// und beide melden dieselbe.
///
/// Wirft nie: lässt sich nichts lesen oder schreiben, gilt eine Kennung nur
/// für diesen Lauf – der Start hängt nie an ihr.
Future<String> sichereInstallationId(
  ConfigStore store, {
  Random? random,
  AgentLog? log,
}) async {
  final zufall = random ?? Random.secure();
  try {
    final datei = store.paths.installationIdFile;
    final ausDatei = await _lies(datei);
    final vorhanden = (await store.load()).installationId;
    final String id;
    if (vorhanden != null) {
      id = vorhanden;
    } else {
      final neu = await store.mutate(
        (current) => current.installationId != null
            ? current
            : current.copyWith(
                installationId: ausDatei ?? neueInstallationId(zufall),
              ),
      );
      id = neu.installationId!;
      log?.info(
        id == ausDatei
            ? 'Installationskennung aus $installationIdDateiName '
                  'wiederhergestellt: $id'
            : 'Installationskennung angelegt: $id',
      );
    }
    if (ausDatei != id) await _schreibe(datei, id, log);
    return id;
  } on Object catch (e) {
    final ersatz = neueInstallationId(zufall);
    log?.warn(
      'Installationskennung nicht lesbar oder nicht speicherbar ($e) – '
      'für diesen Lauf $ersatz.',
    );
    return ersatz;
  }
}

/// Name der zweiten Ablage (siehe [ConfigPaths.installationIdFile]).
const String installationIdDateiName = 'installation-id';

/// Die Kennung aus [datei]; `null`, wenn sie fehlt oder keine gültige ist.
Future<String?> _lies(File datei) async {
  try {
    if (!datei.existsSync()) return null;
    final text = (await datei.readAsString()).trim();
    return isInstallationId(text) ? text : null;
  } on FileSystemException {
    return null;
  }
}

/// Schreibt [id] nach [datei]; ein Fehler kostet nur die zweite Ablage.
Future<void> _schreibe(File datei, String id, AgentLog? log) async {
  try {
    await datei.writeAsString('$id\n', flush: true);
  } on FileSystemException catch (e) {
    log?.warn('$installationIdDateiName nicht schreibbar: ${e.message}');
  }
}
