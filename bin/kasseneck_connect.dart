import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  // Ausdrücklich beenden: ein noch laufendes Kindprogramm oder ein offener
  // Zeitgeber hielte den Prozess sonst am Leben — ein Installer, der auf
  // `zertifikat-vertrauen` wartet, warte dann mit.
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
