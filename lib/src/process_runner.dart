import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Startet ein Programm und wartet auf das Ergebnis — in Tests austauschbar.
///
/// Alle Stellen, die von außen etwas aufrufen (Browser öffnen, `launchctl`,
/// `schtasks`, `systemctl`), gehen über diesen Typ. Im Test steht dort ein
/// Doppelgänger, der die Aufrufe nur mitschreibt: kein Testlauf darf am
/// echten System herumschrauben.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Startet ein Programm und gibt den laufenden Prozess heraus — für Aufrufe,
/// die hängen können (eine Frage an den Benutzer, eine Abfrage des
/// Schlüsselbunds) und dann beendet werden müssen. In Tests austauschbar wie
/// [ProcessRunner]; ausgeführt wird über [runWithTimeout].
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// So lange bekommt ein Programm nach SIGTERM, bevor SIGKILL kommt.
const Duration processKillGrace = Duration(seconds: 2);

/// Führt [executable] über [start] aus und wartet höchstens [timeout].
///
/// Läuft es länger, wird es beendet — erst SIGTERM, nach [killGrace] SIGKILL —
/// und das Ergebnis ist `null`. Ein bloßes `.timeout()` auf [Process.run]
/// gäbe nur das Warten auf: das Programm liefe weiter, und der Dart-Prozess
/// endete erst mit ihm. Ein Installer, der auf `zertifikat-vertrauen` wartet,
/// hinge dann trotz Zeitgrenze.
///
/// `null` auch, wenn sich das Programm nicht starten lässt.
Future<ProcessResult?> runWithTimeout(
  ProcessStarter start,
  String executable,
  List<String> arguments,
  Duration timeout, {
  Duration killGrace = processKillGrace,
}) async {
  final Process process;
  try {
    process = await start(executable, arguments);
  } on ProcessException {
    return null;
  }
  // Beide Ausgaben sofort lesen: ein voller Puffer hielte das Programm an.
  const decoder = Utf8Decoder(allowMalformed: true);
  final output = process.stdout.transform(decoder).join();
  final errors = process.stderr.transform(decoder).join();
  try {
    final code = await process.exitCode.timeout(timeout);
    return ProcessResult(process.pid, code, await output, await errors);
  } on TimeoutException {
    process.kill();
    try {
      await process.exitCode.timeout(killGrace);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    // Die Ausgaben enden mit dem Programm; abgewartet werden sie nicht mehr.
    unawaited(output.then<void>((_) {}, onError: (Object _) {}));
    unawaited(errors.then<void>((_) {}, onError: (Object _) {}));
    return null;
  } on ProcessException {
    // Ein Starter aus einem Runner meldet ein fehlendes Programm erst hier.
    return null;
  }
}

/// Macht aus einem [ProcessRunner] einen [ProcessStarter].
///
/// Für Tests und Einbettungen, die nur einen Runner hereinreichen: so laufen
/// auch die Aufrufe mit Zeitgrenze über ihn statt am System vorbei. Beenden
/// kann dieser Prozess das Programm nicht ([Process.kill] liefert `false`);
/// nach der Zeitgrenze wird es nur nicht mehr abgewartet. Im Betrieb steht
/// deshalb [Process.start] dort.
ProcessStarter processStarterFrom(ProcessRunner run) =>
    (executable, arguments) async => _RunnerProcess(run(executable, arguments));

/// Ein Prozess, dessen Ergebnis ein [ProcessRunner] liefert.
class _RunnerProcess implements Process {
  _RunnerProcess(Future<ProcessResult> result) {
    // Ein Fehler (Programm fehlt) kann eintreffen, bevor jemand auf
    // [exitCode] hört — er gilt trotzdem als behandelt und erreicht spätere
    // Zuhörer.
    _exitCode.future.ignore();
    result.then(
      (value) {
        _stdout
          ..add(_bytes(value.stdout))
          ..close();
        _stderr
          ..add(_bytes(value.stderr))
          ..close();
        _exitCode.complete(value.exitCode);
      },
      onError: (Object error, StackTrace stackTrace) {
        _stdout.close();
        _stderr.close();
        _exitCode.completeError(error, stackTrace);
      },
    );
  }

  final Completer<int> _exitCode = Completer<int>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();

  static List<int> _bytes(Object? value) =>
      value is List<int> ? value : utf8.encode('${value ?? ''}');

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  int get pid => 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
