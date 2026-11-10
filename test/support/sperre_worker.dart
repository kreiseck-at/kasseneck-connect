import 'dart:io';

/// Hilfsprogramm: hält die Sperre `config.lock` in [verzeichnis] wie ein
/// zweiter Connect-Prozess, meldet `bereit` und gibt sie erst frei, wenn
/// seine Standardeingabe endet.
///
/// Aufruf: `dart run test/support/sperre_worker.dart <verzeichnis>`
Future<void> main(List<String> arguments) async {
  final datei = File('${arguments.single}/config.lock');
  final handle = await datei.open(mode: FileMode.write);
  await handle.lock(FileLock.blockingExclusive);
  stdout.writeln('bereit');
  await stdin.drain<void>();
  await handle.unlock();
  await handle.close();
}
