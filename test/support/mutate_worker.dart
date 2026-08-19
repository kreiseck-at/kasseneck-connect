import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

/// Hilfsprogramm des Nebenläufigkeitstests: schreibt [count] Einträge über
/// `ConfigStore.mutate` in dasselbe Verzeichnis wie ein zweiter Prozess.
///
/// Aufruf: `dart run test/support/mutate_worker.dart <verzeichnis> <präfix> <anzahl>`
Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments[0]);
  final prefix = arguments[1];
  final count = int.parse(arguments[2]);
  final store = ConfigStore.forDirectory(directory);

  for (var i = 0; i < count; i++) {
    await store.mutate(
      (current) => current.copyWith(
        tokenHashes: <String>[...current.tokenHashes, '$prefix-$i'],
      ),
    );
  }
}
