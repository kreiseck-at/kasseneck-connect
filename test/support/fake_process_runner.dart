import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';

/// Ein aufgezeichneter Programmstart.
class RecordedCall {
  const RecordedCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  /// Kommandozeile als eine Zeile — nur für lesbare Fehlermeldungen und für
  /// Erwartungen ohne Leerzeichen in den Argumenten. Wer es genau will,
  /// nimmt [FakeProcessRunner.sawCall] oder [arguments] direkt.
  String get line => <String>[executable, ...arguments].join(' ');

  @override
  String toString() => line;
}

/// Doppelgänger für [ProcessRunner]: schreibt alle Aufrufe mit und antwortet
/// nach hinterlegten Regeln. **Kein Test startet ein echtes Programm** —
/// außer denen, die er ausdrücklich in [echt] einträgt.
class FakeProcessRunner {
  FakeProcessRunner({this.defaultExitCode = 0});

  /// Exitcode für alles, wofür keine eigene Regel hinterlegt ist.
  final int defaultExitCode;

  /// Alle Aufrufe in ihrer Reihenfolge.
  final List<RecordedCall> calls = <RecordedCall>[];

  /// Exitcode je erstem Argument (z. B. `bootstrap` → 1).
  final Map<String, int> exitCodes = <String, int>{};

  /// Exitcodes je erstem Argument als FOLGE: je Aufruf wird einer verbraucht,
  /// danach gelten wieder [exitCodes]/[defaultExitCode]. Für Abläufe wie
  /// „bootstrap scheitert zweimal, dann klappt es".
  final Map<String, List<int>> exitCodeFolge = <String, List<int>>{};

  /// Standardausgabe je erstem Argument.
  final Map<String, String> stdoutOf = <String, String>{};

  /// Programme, die es angeblich gar nicht gibt.
  final Set<String> missing = <String>{};

  /// Programme, die wirklich laufen — etwa `/usr/bin/openssl` und `chmod`,
  /// wenn ein Test echte Zertifikate braucht. Mitgeschrieben werden sie
  /// trotzdem. `security` und `launchctl` nimmt die Attrappe hier nie an:
  /// kein Test fasst den Schlüsselbund oder launchd an.
  final Set<String> echt = <String>{};

  /// Eigene Antwort je Aufruf, wenn die Regeln oben nicht reichen — etwa eine
  /// Ausgabe, die vom Inhalt einer Datei abhängt (`openssl x509 -in …`).
  /// Liefert sie `null`, gelten [exitCodes], [stdoutOf] usw.
  Future<ProcessResult?> Function(String executable, List<String> arguments)?
  antwort;

  /// Der einsetzbare [ProcessRunner].
  ProcessRunner get runner => _run;

  /// Der einsetzbare [ProcessStarter]: dieselben Regeln, aber als laufender
  /// Prozess. Wird eine Antwort nie fertig (eigene [antwort], die hängt),
  /// endet der Prozess erst mit [Process.kill] — und steht dann in [killed].
  ProcessStarter get starter => _start;

  /// Aufrufe, deren Prozess per [Process.kill] beendet wurde.
  final List<RecordedCall> killed = <RecordedCall>[];

  /// Alle Kommandozeilen als Text.
  List<String> get lines => calls.map((call) => call.line).toList();

  /// Ob irgendein Aufruf mit [executable] und genau diesen Argumenten kam.
  /// Verglichen wird **Argument für Argument**, nicht über eine
  /// zusammengefügte Zeile: `['/TN', 'Kasseneck Connect']` und
  /// `['/TN Kasseneck', 'Connect']` ergäben dieselbe Zeile, sind als Aufruf
  /// aber etwas völlig anderes. Genau solche Argumente mit Leerzeichen kommen
  /// bei `schtasks` vor.
  bool sawCall(String executable, List<String> arguments) => calls.any(
    (call) =>
        call.executable == executable &&
        _sameArguments(call.arguments, arguments),
  );

  static bool _sameArguments(List<String> actual, List<String> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    calls.add(RecordedCall(executable, arguments));
    if (missing.contains(executable)) {
      throw ProcessException(executable, arguments, 'Programm nicht gefunden');
    }
    if (_istEcht(executable)) return Process.run(executable, arguments);
    return _antwort(executable, arguments);
  }

  Future<Process> _start(String executable, List<String> arguments) async {
    final call = RecordedCall(executable, arguments);
    calls.add(call);
    if (missing.contains(executable)) {
      throw ProcessException(executable, arguments, 'Programm nicht gefunden');
    }
    if (_istEcht(executable)) return Process.start(executable, arguments);
    return _FakeProcess(
      _antwort(executable, arguments),
      onKill: () => killed.add(call),
    );
  }

  bool _istEcht(String executable) {
    if (!echt.contains(executable)) return false;
    final name = executable.split('/').last;
    if (name == 'security' || name == 'launchctl') {
      throw StateError('$name läuft im Test nie echt.');
    }
    return true;
  }

  Future<ProcessResult> _antwort(
    String executable,
    List<String> arguments,
  ) async {
    final eigene = await antwort?.call(executable, arguments);
    if (eigene != null) return eigene;
    final key = arguments.isEmpty ? '' : arguments.first;
    final folge = exitCodeFolge[key];
    final code = folge != null && folge.isNotEmpty
        ? folge.removeAt(0)
        : (exitCodes[key] ?? defaultExitCode);
    return ProcessResult(42, code, stdoutOf[key] ?? '', '');
  }
}

/// Laufender Prozess der Attrappe: endet mit der Antwort oder mit [kill].
class _FakeProcess implements Process {
  _FakeProcess(Future<ProcessResult> result, {required void Function() onKill})
    : _onKill = onKill {
    result.then(
      (value) {
        if (_exitCode.isCompleted) return;
        _stdout
          ..add(utf8.encode('${value.stdout}'))
          ..close();
        _stderr
          ..add(utf8.encode('${value.stderr}'))
          ..close();
        _exitCode.complete(value.exitCode);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_exitCode.isCompleted) return;
        _stdout.close();
        _stderr.close();
        _exitCode.completeError(error, stackTrace);
      },
    );
  }

  final void Function() _onKill;
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_exitCode.isCompleted) return false;
    _onKill();
    _stdout.close();
    _stderr.close();
    _exitCode.complete(-15);
    return true;
  }
}
