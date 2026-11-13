import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'logger.dart';

/// Ausgabe und Fehlerausgabe des LaunchAgents (`autostart/macos.dart`). launchd
/// hängt dort an, solange der Rechner läuft, und kürzt nie.
const List<String> launchdLogNamen = <String>[
  'launchd.out.log',
  'launchd.err.log',
];

/// Ab dieser Größe kürzt der Start die Datei. Im Normalbetrieb schreibt der
/// Agent dort fast nichts (das eigene Log ist `connect.log`); 1 MB erreicht
/// nur eine Datei, in die etwas in Schleife schreibt.
const int launchdLogGrenze = 1024 * 1024;

/// So viel vom Ende bleibt stehen: genug für die letzten Abstürze.
const int launchdLogRest = 256 * 1024;

/// Wo der behaltene Rest in [ende] (den letzten [launchdLogRest] Bytes)
/// beginnt: nach dem ersten Zeilenumbruch, damit keine halbe Zeile vorn steht.
/// Ohne Umbruch bleibt alles.
int restAnfang(Uint8List ende) {
  final umbruch = ende.indexOf(0x0A);
  return umbruch < 0 ? 0 : umbruch + 1;
}

/// Kürzt die launchd-Logs in [verzeichnis] auf die letzten [rest] Bytes, wenn
/// sie größer als [grenze] sind. Wirft nie.
///
/// Gekürzt wird an Ort und Stelle (öffnen mit Abschneiden, Rest schreiben),
/// nicht durch Ersetzen der Datei: launchd hat sie dem Agenten als
/// Standardausgabe geöffnet, und ein Ersetzen ließe ihn in die gelöschte
/// Datei weiterschreiben. launchd öffnet sie zum Anhängen (`O_APPEND`), die
/// nächste Zeile landet also hinter dem Rest (im Gerätetest zu bestätigen).
void kuerzeLaunchdLogs(
  Directory verzeichnis, {
  AgentLog? log,
  int grenze = launchdLogGrenze,
  int rest = launchdLogRest,
}) {
  for (final name in launchdLogNamen) {
    final datei = File(p.join(verzeichnis.path, name));
    try {
      if (!datei.existsSync()) continue;
      final groesse = datei.lengthSync();
      if (groesse <= grenze) continue;
      final lesen = datei.openSync();
      final Uint8List ende;
      try {
        lesen.setPositionSync(groesse - rest);
        ende = lesen.readSync(rest);
      } finally {
        lesen.closeSync();
      }
      final behalten = Uint8List.sublistView(ende, restAnfang(ende));
      datei.writeAsBytesSync(behalten, flush: true);
      log?.info(
        '$name gekürzt: ${groesse ~/ 1024} KB → ${behalten.length ~/ 1024} KB.',
      );
    } on FileSystemException catch (e) {
      // Kein Grund, den Start aufzuhalten: die Datei wächst dann weiter wie
      // bis 1.4.2.
      log?.warn('$name ließ sich nicht kürzen: ${e.message}');
    }
  }
}
