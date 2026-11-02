import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;

/// Hilfsprogramm des Nebenläufigkeitstests: meldet sich bereit, wartet auf die
/// Startdatei und ruft dann `LocalCertificates.ensure()` auf — gleichzeitig
/// mit einem zweiten Prozess im selben Verzeichnis. So wie `run` und der
/// Befehl `zertifikat-vertrauen` bei der Installation.
///
/// Aufruf: `dart run test/support/tls_worker.dart <verzeichnis> <openssl> <startdatei> <name>`
Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments[0]);
  final openssl = arguments[1];
  final start = File(arguments[2]);
  final name = arguments[3];

  File(p.join(directory.path, 'bereit-$name')).writeAsStringSync(name);
  while (!start.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  final files = await LocalCertificates(
    directory: directory,
    run: Process.run,
    log: AgentLog(Directory(p.join(directory.path, 'logs-$name'))),
    openssl: openssl,
  ).ensure();
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'caCreated': files.caCreated,
      'ca': File(files.caCertPath).readAsStringSync(),
    }),
  );
}
