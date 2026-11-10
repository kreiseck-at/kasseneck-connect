import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

/// Hilfsprogramm des Absturztests: beginnt einen Vorgang (schreibt
/// `betrieb.lock`), meldet `bereit` und wartet, bis es hart beendet wird.
///
/// Aufruf: `dart run test/support/betrieb_worker.dart <verzeichnis>`
Future<void> main(List<String> arguments) async {
  final store = ConfigStore.forDirectory(Directory(arguments.single));
  final lock = BetriebsLock(store: store);
  LaufendeVorgaenge(
    beobachter: <BetriebsBeobachter>[lock],
  ).beginne(VorgangsArt.terminal);
  await lock.erledigt;
  stdout.writeln('bereit');
  await Completer<void>().future;
}
