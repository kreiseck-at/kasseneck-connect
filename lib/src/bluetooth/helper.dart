/// Das Bluetooth-Hilfsprogramm als Kindprozess: bei Bedarf starten, mit
/// Herzschlag überwachen und nach Absturz oder Hänger ersetzen.
///
/// Das Hilfsprogramm übersetzt nur (`docs/bluetooth-protokoll.md`); hier
/// liegt, was es nicht entscheidet: wann es läuft, wie lange ein Aufruf
/// warten darf und wie schnell nach einem Absturz ein neues startet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../log/logger.dart';
import '../process_runner.dart';
import 'protocol.dart';

/// Name des Hilfsprogramms im App-Paket, neben der Binary des Agenten.
const String bluetoothHelperName = 'kasseneck-bluetooth';

/// Umgebungsvariable mit dem Pfad zu einem anderen Hilfsprogramm
/// (Entwicklung und Gerätetest ohne App-Paket).
const String bluetoothHelperEnvVar = 'KASSENECK_CONNECT_BT_HELPER';

/// Zustand, solange das Hilfsprogramm zum ersten Mal startet.
const String helperStateStarting = 'starting';

/// Zustand nach einem Absturz oder Hänger, bis das neue Hilfsprogramm seinen
/// Zustand meldet.
const String helperStateRestarting = 'helper_restarting';

const String _unknown = 'unknown';
const String _unavailable = 'bluetooth_unavailable';
const String _unsupported = 'bluetooth_unsupported';

/// Antwortet ein `ping` nicht binnen dieser Zeit, gilt das Hilfsprogramm als
/// hängend.
const Duration _pingTimeout = Duration(seconds: 3);

/// Pausen vor dem nächsten Start nach Abstürzen in Folge; die letzte ist der
/// Deckel. So startet ein Hilfsprogramm, das sofort wieder stirbt, nicht im
/// Sekundentakt neu.
const List<Duration> _restartPauses = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

/// Nach so langem ruhigem Lauf beginnt die Pause wieder bei der ersten Stufe.
const Duration _calmAfter = Duration(seconds: 60);

/// So lange darf das Hilfsprogramm nach dem Schließen von stdin brauchen.
const Duration _stopGrace = Duration(seconds: 2);

/// Endet das Hilfsprogramm, ohne stdout zu schließen, gilt es nach dieser
/// Zeit trotzdem als beendet.
const Duration _exitGrace = Duration(seconds: 1);

/// Fehler eines Bluetooth-Aufrufs.
///
/// [code] ist bei einer Fehlerantwort der Code des Hilfsprogramms
/// (`not_connected`, `unauthorized` …), sonst `bluetooth_unavailable` bzw.
/// `bluetooth_unsupported`. [message] ist nur fürs Protokoll; den Klartext
/// für die Kasse macht die Brücke.
class BluetoothFailure implements Exception {
  const BluetoothFailure(this.code, this.message, {this.detail});

  final String code;
  final String message;
  final Object? detail;

  @override
  String toString() => 'BluetoothFailure($code, $message)';
}

/// Zugang zum Bluetooth-Hilfsprogramm.
abstract interface class BluetoothHelper {
  /// Ereignisse des Hilfsprogramms (`state`, `discovered`, `connected` …).
  ///
  /// Dazu kommen eigene: `state` mit `starting` bzw. `helper_restarting`,
  /// und endet das Hilfsprogramm, `disconnected` für jedes Gerät, das noch
  /// verbunden war – wie beim Verlust einer Verbindung.
  Stream<HelperEvent> get events;

  /// Funkzustand aus dem letzten `state`-Ereignis; vor dem ersten Start
  /// `unknown`, beim Start `starting`, nach einem Absturz bis zur nächsten
  /// Meldung `helper_restarting`, ohne Hilfsprogramm `unsupported`.
  String get state;

  /// Schickt einen Befehl ([HelperOp]) und liefert dessen `result`.
  ///
  /// Startet das Hilfsprogramm, wenn es nicht läuft. Wirft
  /// [BluetoothFailure]: mit dem Code des Hilfsprogramms bei einer
  /// Fehlerantwort, sonst `bluetooth_unavailable`.
  Future<Map<String, Object?>> call(String op, [Map<String, Object?> args]);

  /// Beendet das Hilfsprogramm; danach scheitert jeder Aufruf.
  Future<void> stop();
}

/// Hilfsprogramm als Kindprozess mit stdin/stdout-Zeilen.
///
/// Der Prozess startet erst mit dem ersten [call] (nie im Konstruktor), damit
/// der Start des Agenten keine Bluetooth-Freigabe auslöst. Solange er läuft,
/// geht alle [heartbeat] ein `ping` hinaus; bleibt die Antwort 3 s aus, wird
/// er beendet. Nach einem Absturz startet erst der nächste Aufruf ein neues
/// Hilfsprogramm, und frühestens nach der Pause der Rückzugsfolge
/// (1, 2, 5, 10, 30 s; nach 60 s ruhigem Lauf wieder 1 s). Ein Aufruf wartet
/// eine Pause ab, die kürzer ist als [callTimeout]; bei längerer scheitert
/// er sofort.
class ProcessBluetoothHelper implements BluetoothHelper {
  ProcessBluetoothHelper({
    required this.executable,
    required this.log,
    ProcessStarter? start,
    this.heartbeat = const Duration(seconds: 5),
    this.callTimeout = const Duration(seconds: 15),
  }) : _start = start ?? Process.start;

  /// Pfad zum Hilfsprogramm.
  final String executable;
  final AgentLog log;

  /// Abstand der `ping`.
  final Duration heartbeat;

  /// Höchstdauer eines Aufrufs, Start und Pause eingerechnet.
  final Duration callTimeout;

  final ProcessStarter _start;
  final StreamController<HelperEvent> _events =
      StreamController<HelperEvent>.broadcast();
  final Map<int, _Call> _calls = <int, _Call>{};

  int _nextId = 1;
  String _state = _unknown;
  bool _started = false;
  bool _stopped = false;
  _Run? _run;
  Future<_Run>? _starting;

  /// Abstürze in Folge; bestimmt die nächste Pause.
  int _failures = 0;
  Duration _pause = Duration.zero;
  Timer? _pauseTimer;
  Completer<void>? _pauseOver;

  @override
  Stream<HelperEvent> get events => _events.stream;

  @override
  String get state => _state;

  @override
  Future<Map<String, Object?>> call(
    String op, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) {
    if (_stopped) return Future.error(_stoppedFailure);
    final id = _nextId++;
    final pending = _Call(op);
    _calls[id] = pending;
    pending.timeout = Timer(callTimeout, () {
      if (_calls.remove(id) == null) return;
      // Die Antwort kann noch kommen (z. B. hinter dem ersten
      // Freigabe-Dialog); sie wird dann still verworfen.
      log.warn(
        'Bluetooth-Hilfsprogramm: keine Antwort auf $op nach '
        '${callTimeout.inSeconds} s.',
      );
      pending.completer.completeError(
        const BluetoothFailure(
          _unavailable,
          'Das Bluetooth-Hilfsprogramm hat nicht rechtzeitig geantwortet.',
        ),
      );
    });
    unawaited(
      _ensureRunning().then<void>(
        (run) {
          if (!identical(_calls[id], pending)) return;
          if (run.ended) {
            _fail(id, _crashedFailure);
            return;
          }
          pending.run = run;
          _write(run, HelperRequest(id, op, args));
        },
        onError: (Object error) {
          _fail(id, error is BluetoothFailure ? error : _startFailure);
        },
      ),
    );
    return pending.completer.future;
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    final pauseOver = _pauseOver;
    _pauseOver = null;
    // Wer auf das Ende der Pause wartet, sieht jetzt `_stopped`.
    pauseOver?.complete();

    final run = _run;
    if (run != null) {
      // Das Hilfsprogramm endet bei EOF auf stdin von selbst.
      try {
        unawaited(
          run.process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
        );
      } on Object {
        // stdin war schon zu – dann bleibt nur das Warten.
      }
      await run.process.exitCode.timeout(
        _stopGrace,
        onTimeout: () {
          run.process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _ended(run, 'gestoppt');
    }
    for (final id in _calls.keys.toList()) {
      _fail(id, _stoppedFailure);
    }
    _setState(_unknown);
    unawaited(_events.close());
  }

  // ---------------------------------------------------------------------------
  // Start und Pause

  Future<_Run> _ensureRunning() {
    final run = _run;
    if (run != null && !run.ended) return Future.value(run);
    if (_stopped) return Future.error(_stoppedFailure);
    // Eine Pause, die länger dauert, als ein Aufruf warten darf: gleich
    // ablehnen statt die Kasse bis zum Zeitlimit hängen zu lassen.
    if (_pauseOver != null && _pause >= callTimeout) {
      return Future.error(
        const BluetoothFailure(
          _unavailable,
          'Das Bluetooth-Hilfsprogramm startet gerade neu.',
        ),
      );
    }
    return _starting ??= _launch();
  }

  /// Startet das Hilfsprogramm, nach einer laufenden Pause.
  ///
  /// Setzt [_starting] erst nach dem ersten `await` zurück – vorher ist es
  /// noch gar nicht gesetzt.
  Future<_Run> _launch() async {
    final pauseOver = _pauseOver;
    if (pauseOver != null) await pauseOver.future;
    if (!_started) _setState(helperStateStarting);
    _started = true;

    final Process process;
    try {
      if (_stopped) throw _stoppedFailure;
      process = await Future<Process>.sync(
        () => _start(executable, const <String>[]),
      );
    } on BluetoothFailure {
      _starting = null;
      rethrow;
    } on Object catch (error) {
      _starting = null;
      log.error('Bluetooth-Hilfsprogramm startet nicht', error);
      _scheduleRestart();
      throw _startFailure;
    }
    _starting = null;
    if (_stopped) {
      process.kill(ProcessSignal.sigkill);
      throw _stoppedFailure;
    }

    final run = _Run(process);
    _run = run;
    _attach(run);
    log.info('Bluetooth-Hilfsprogramm gestartet.');
    return run;
  }

  void _attach(_Run run) {
    final process = run.process;
    // Schreibfehler auf stdin (Hilfsprogramm schon weg) landen sonst als
    // unbehandelter Fehler im Agenten.
    unawaited(process.stdin.done.then<void>((_) {}, onError: (Object _) {}));
    run.stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _onLine(run, line),
          onError: (Object _) {},
          onDone: () => _ended(run, 'stdout geschlossen'),
        );
    run.stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onNote, onError: (Object _) {});
    unawaited(
      process.exitCode.then((code) {
        run.exitCode = code;
        if (!run.ended) {
          run.exitGrace = Timer(_exitGrace, () => _ended(run, 'beendet'));
        }
      }),
    );
    run.heartbeat = Timer.periodic(heartbeat, (_) => _beat(run));
    run.calm = Timer(_calmAfter, () {
      if (identical(_run, run)) _failures = 0;
    });
  }

  /// Plant die Pause vor dem nächsten Start; erst ein Aufruf startet dann.
  void _scheduleRestart() {
    final pause =
        _restartPauses[math.min(_failures, _restartPauses.length - 1)];
    _failures++;
    _pause = pause;
    // Wer schon wartet, wartet auf die neue Pause weiter.
    final over = _pauseOver ??= Completer<void>();
    _pauseTimer?.cancel();
    _pauseTimer = Timer(pause, () {
      _pauseTimer = null;
      _pauseOver = null;
      over.complete();
    });
    _setState(helperStateRestarting);
    log.warn(
      'Bluetooth-Hilfsprogramm: Neustart frühestens in ${pause.inSeconds} s, '
      'beim nächsten Aufruf.',
    );
  }

  /// Der Prozess ist weg (Absturz, Hänger oder [stop]).
  void _ended(_Run run, String reason) {
    if (run.ended) return;
    run.ended = true;
    run.cancel();
    if (identical(_run, run)) _run = null;
    // Nichts zurücklassen, falls nur stdout zu ist.
    if (run.exitCode == null) run.process.kill(ProcessSignal.sigkill);

    final code = run.exitCode;
    if (_stopped) {
      log.info('Bluetooth-Hilfsprogramm beendet.');
    } else {
      log.warn(
        'Bluetooth-Hilfsprogramm beendet ($reason'
        '${code == null ? '' : ', Code $code'}).',
      );
    }
    final failure = _stopped ? _stoppedFailure : _crashedFailure;
    for (final entry in _calls.entries.toList()) {
      if (identical(entry.value.run, run)) _fail(entry.key, failure);
    }
    if (!_stopped) _scheduleRestart();
    for (final device in run.connected) {
      _emit(
        HelperEvent(HelperEventName.disconnected, {
          'device': device,
          'reason': 'bluetooth helper exited',
        }),
      );
    }
    run.connected.clear();
  }

  // ---------------------------------------------------------------------------
  // Herzschlag

  void _beat(_Run run) {
    if (run.ended || run.pingId != null) return;
    final id = _nextId++;
    run.pingId = id;
    _write(run, HelperRequest(id, HelperOp.ping));
    run.pingDeadline = Timer(_pingTimeout, () {
      if (run.ended || run.pingId != id) return;
      log.warn(
        'Bluetooth-Hilfsprogramm antwortet nicht auf den Herzschlag; '
        'es wird beendet.',
      );
      run.process.kill(ProcessSignal.sigkill);
      _ended(run, 'Herzschlag ohne Antwort');
    });
  }

  // ---------------------------------------------------------------------------
  // Zeilen

  void _write(_Run run, HelperRequest request) {
    try {
      run.process.stdin.add(utf8.encode('${request.encode()}\n'));
    } on Object catch (error) {
      // Der Prozess ist weg; das Ende meldet stdout.
      log.debug('Bluetooth-Hilfsprogramm: Schreiben gescheitert: $error');
    }
  }

  void _onLine(_Run run, String line) {
    // Zeilen eines abgelösten Hilfsprogramms zählen nicht mehr.
    if (run.ended) return;
    final message = decodeHelperLine(line);
    switch (message) {
      case final HelperResponse response:
        _onResponse(run, response);
      case final HelperEvent event:
        _onEvent(run, event);
      case HelperRequest() || null:
        if (line.trim().isEmpty) return;
        // Nie den Inhalt: er könnte Nutzdaten tragen.
        log.warn(
          'Bluetooth-Hilfsprogramm: unlesbare Zeile verworfen '
          '(${line.length} Zeichen).',
        );
    }
  }

  void _onResponse(_Run run, HelperResponse response) {
    if (response.id == run.pingId) {
      run.pingId = null;
      run.pingDeadline?.cancel();
      return;
    }
    final pending = _calls.remove(response.id);
    if (pending == null) {
      // Antwort auf einen Aufruf, den das Zeitlimit schon beendet hat.
      log.debug(
        'Bluetooth-Hilfsprogramm: Antwort auf id ${response.id} verworfen.',
      );
      return;
    }
    pending.timeout?.cancel();
    final error = response.error;
    if (error == null) {
      pending.completer.complete(response.data);
    } else {
      pending.completer.completeError(
        BluetoothFailure(error.code, error.message),
      );
    }
  }

  void _onEvent(_Run run, HelperEvent event) {
    final device = event.data['device'];
    switch (event.event) {
      case HelperEventName.state:
        final state = event.data['state'];
        if (state is String) _state = state;
      case HelperEventName.connected when device is String:
        run.connected.add(device);
      case HelperEventName.disconnected when device is String:
        run.connected.remove(device);
    }
    _emit(event);
  }

  void _onNote(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    final kurz = text.length > 300 ? '${text.substring(0, 300)} …' : text;
    log.info('Bluetooth-Hilfsprogramm meldet: $kurz');
  }

  // ---------------------------------------------------------------------------
  // Hilfen

  void _fail(int id, BluetoothFailure failure) {
    final pending = _calls.remove(id);
    if (pending == null) return;
    pending.timeout?.cancel();
    pending.completer.completeError(failure);
  }

  /// Eigener Zustandswechsel des Aufpassers, als Ereignis gemeldet.
  void _setState(String state) {
    if (_state == state) return;
    _state = state;
    _emit(HelperEvent(HelperEventName.state, {'state': state}));
  }

  void _emit(HelperEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static const BluetoothFailure _crashedFailure = BluetoothFailure(
    _unavailable,
    'Das Bluetooth-Hilfsprogramm wurde unerwartet beendet.',
  );

  static const BluetoothFailure _startFailure = BluetoothFailure(
    _unavailable,
    'Das Bluetooth-Hilfsprogramm lässt sich nicht starten.',
  );

  static const BluetoothFailure _stoppedFailure = BluetoothFailure(
    _unavailable,
    'Bluetooth ist beendet.',
  );
}

/// Ein offener Aufruf.
class _Call {
  _Call(this.op);

  final String op;
  final Completer<Map<String, Object?>> completer =
      Completer<Map<String, Object?>>();
  Timer? timeout;

  /// Der Prozess, an den der Befehl ging; stirbt er, endet der Aufruf.
  _Run? run;
}

/// Ein laufender Prozess des Hilfsprogramms.
class _Run {
  _Run(this.process);

  final Process process;
  StreamSubscription<String>? stdout;
  StreamSubscription<String>? stderr;
  Timer? heartbeat;
  Timer? pingDeadline;
  Timer? calm;
  Timer? exitGrace;
  int? pingId;
  int? exitCode;
  bool ended = false;

  /// Geräte mit `connected` und noch ohne `disconnected`.
  final Set<String> connected = <String>{};

  void cancel() {
    heartbeat?.cancel();
    pingDeadline?.cancel();
    calm?.cancel();
    exitGrace?.cancel();
    unawaited(stdout?.cancel());
    unawaited(stderr?.cancel());
  }
}

/// Ohne Hilfsprogramm (Windows, Linux, macOS ohne App-Paket).
class UnsupportedBluetoothHelper implements BluetoothHelper {
  const UnsupportedBluetoothHelper();

  @override
  Stream<HelperEvent> get events => const Stream<HelperEvent>.empty();

  @override
  String get state => 'unsupported';

  @override
  Future<Map<String, Object?>> call(
    String op, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async => throw const BluetoothFailure(
    _unsupported,
    'Bluetooth gibt es in Kasseneck Connect bisher nur unter macOS.',
  );

  @override
  Future<void> stop() async {}
}

/// Pfad zum Hilfsprogramm dieses Rechners oder `null`.
///
/// Schaut nur ins Dateisystem und berührt Bluetooth nie (auch für `doctor`).
/// Bisher nur unter macOS: [bluetoothHelperEnvVar], sonst
/// `kasseneck-bluetooth` neben der Binary des Agenten.
String? findBluetoothHelper({
  Map<String, String>? environment,
  String? operatingSystem,
  String? executable,
}) {
  if ((operatingSystem ?? Platform.operatingSystem) != 'macos') return null;
  final override = (environment ?? Platform.environment)[bluetoothHelperEnvVar]
      ?.trim();
  final path = override != null && override.isNotEmpty
      ? override
      : p.join(
          p.dirname(executable ?? Platform.resolvedExecutable),
          bluetoothHelperName,
        );
  return File(path).existsSync() ? path : null;
}

/// Der Bluetooth-Zugang dieses Rechners; startet noch nichts.
BluetoothHelper platformBluetoothHelper(
  AgentLog log, {
  Map<String, String>? environment,
  String? operatingSystem,
  String? executable,
  ProcessStarter? start,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final path = findBluetoothHelper(
    environment: env,
    operatingSystem: os,
    executable: executable,
  );
  if (path == null) {
    final override = env[bluetoothHelperEnvVar]?.trim();
    if (os == 'macos' && override != null && override.isNotEmpty) {
      log.warn('$bluetoothHelperEnvVar zeigt auf keine Datei: $override');
    }
    return const UnsupportedBluetoothHelper();
  }
  return ProcessBluetoothHelper(executable: path, log: log, start: start);
}
