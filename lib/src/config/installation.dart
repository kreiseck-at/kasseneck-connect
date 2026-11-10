import 'dart:math';

import '../log/logger.dart';
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
/// Geschrieben wird nur, wenn sie fehlt – und dann unter der Sperre von
/// [ConfigStore.mutate], die selbst noch einmal nachsieht: starten zwei
/// Prozesse zugleich, gewinnt eine Kennung, und beide melden dieselbe.
Future<String> sichereInstallationId(
  ConfigStore store, {
  Random? random,
  AgentLog? log,
}) async {
  final vorhanden = (await store.load()).installationId;
  if (vorhanden != null) return vorhanden;
  final zufall = random ?? Random.secure();
  final neu = await store.mutate(
    (current) => current.installationId != null
        ? current
        : current.copyWith(installationId: neueInstallationId(zufall)),
  );
  final id = neu.installationId!;
  log?.info('Installationskennung angelegt: $id');
  return id;
}
