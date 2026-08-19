import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
