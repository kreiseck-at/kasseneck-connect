/// Verbindungen zu Bluetooth-Geräten bei Bedarf: verbinden, kurz nachhalten,
/// während des Bedarfs still neu verbinden und Abos wiederherstellen.
///
/// Gerätewissen gibt es hier keines: Meldungen werden gepuffert und
/// weitergereicht, nie gedeutet.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../events/bus.dart';
import '../log/logger.dart';
import 'helper.dart';
import 'protocol.dart';
import 'uuids.dart';

const String _codeUnreachable = 'bluetooth_unreachable';
const String _codeNotFound = 'bluetooth_device_not_found';
const String _codeDisconnected = 'bluetooth_disconnected';
const String _codeUnavailable = 'bluetooth_unavailable';

/// Gründe im Ereignis `bluetooth.device`, wenn Connect selbst getrennt hat.
const String _reasonIdle = 'idle';
const String _reasonReleased = 'released';
const String _reasonReset = 'reset';
const String _reasonTimeout = 'timeout';
const String _reasonNotNeeded = 'not needed';
const String _reasonRestoreFailed = 'restore failed';
const String _reasonUnrequested = 'unrequested';

/// Fehler des Hilfsprogramms, nach denen erst ein anderer Funkzustand hilft.
const Set<String> _radioCodes = <String>{
  HelperErrorCode.bluetoothOff,
  HelperErrorCode.unauthorized,
  HelperErrorCode.bluetoothUnsupported,
};

/// Pause vor dem nächsten Versuch, wenn das Hilfsprogramm gerade nicht
/// erreichbar ist (es startet erst auf einen Aufruf hin neu).
const Duration _retryPause = Duration(seconds: 5);

/// Meldungen bis zu dieser Länge dürfen als Hex ins Log (Statuskanal).
const int _logBytes = 8;

const BluetoothFailure _unreachable = BluetoothFailure(
  _codeUnreachable,
  'Nicht erreichbar – vielleicht mit einem anderen Gerät verbunden.',
);

const BluetoothFailure _notFound = BluetoothFailure(
  _codeNotFound,
  'Dieser Mac kennt das Gerät nicht mehr – bitte neu suchen.',
);

const BluetoothFailure _ended = BluetoothFailure(
  _codeDisconnected,
  'Die Verbindung wurde getrennt.',
);

const BluetoothFailure _closedFailure = BluetoothFailure(
  _codeUnavailable,
  'Bluetooth ist beendet.',
);

/// `connect` kam ohne vorheriges `connected` zurück oder die Verbindung fiel
/// beim Wiederherstellen der Abos – wie ein `not_connected` behandelt.
const BluetoothFailure _linkMissing = BluetoothFailure(
  HelperErrorCode.notConnected,
  'Die Verbindung ist beim Aufbau weggefallen.',
);

/// Eine Meldung (notify/indicate) eines abonnierten Merkmals.
class NotificationEntry {
  NotificationEntry({
    required this.service,
    required this.characteristic,
    required this.data,
    required this.at,
    required this.generation,
    required this.seq,
  });

  /// Dienst und Merkmal, lang und klein.
  final String service;
  final String characteristic;

  /// Die Bytes, ungedeutet.
  final Uint8List data;

  /// Empfangszeit im Agenten.
  final DateTime at;

  /// Verbindungsnummer, unter der die Meldung kam.
  final int generation;

  /// Laufende Nummer je Gerät, über alle Verbindungen hinweg.
  final int seq;

  Map<String, Object?> toJson() => <String, Object?>{
    'service': service,
    'characteristic': characteristic,
    'data': base64Encode(data),
    'at': at.toUtc().toIso8601String(),
    'generation': generation,
    'seq': seq,
  };
}

/// Verbindungen je Gerät, so wie die Kasse sie braucht.
///
/// * **Bedarf:** [demand] verbindet (oder findet die Verbindung vor) und
///   startet das Nachhalten neu; gleichzeitige Aufrufe teilen sich einen
///   Verbindungsaufbau. Läuft das Nachhalten (`linger`) ohne Zugriff ab, wird
///   getrennt, und Abos und Puffer sind verworfen; [release] tut das sofort.
/// * **Halten:** solange [hold] gilt (eine Belegung), läuft kein Nachhalten.
/// * **Neu verbinden:** fällt eine Verbindung, während das Gerät gehalten wird
///   (oder während ein [demand] auf sie wartet), verbindet die Klasse still
///   neu, sobald Funk und Gerät es zulassen, und stellt zuerst jedes Abo
///   dieses Bedarfs wieder her; erst dann meldet sie die neue
///   Verbindungsnummer als verbunden. Fällt sie im bloßen Nachhalten (der
///   Drucker trennt die leere Verbindung, Bluetooth geht aus), bleibt sie zu:
///   der nächste [demand] verbindet und bringt die Abos dieses Bedarfs mit.
///   So greift Connect nach einem Abbruch nicht von selbst wieder zu, wenn
///   inzwischen etwa die Kassen-App den Drucker übernommen hat.
/// * **Zeitlimit:** ein Verbindungsaufbau wartet höchstens `connectTimeout`;
///   dann bricht er ab (CoreBluetooth selbst wartet ohne Ende) und meldet
///   `bluetooth_unreachable`. Kennt der Mac das Gerät nicht, kommt sofort
///   `bluetooth_device_not_found`; ist Bluetooth aus oder ohne Freigabe,
///   sofort der Code des Hilfsprogramms.
///
/// Jede neue Verbindung bekommt eine fortlaufende Verbindungsnummer, damit
/// die Kasse erkennt, dass der Gerätestand neu beginnt. Meldungen gehen als
/// `bluetooth.notification` hinaus und liegen je Merkmal in einem Puffer der
/// laufenden Verbindung (`bufferSize`).
///
/// Gründe in `bluetooth.device`, wenn Connect selbst trennt: `idle`
/// (Nachhalten abgelaufen), `released`, `reset`; sonst der Grund des
/// Hilfsprogramms.
class BluetoothConnections {
  BluetoothConnections({
    required BluetoothHelper helper,
    required EventBus events,
    required AgentLog log,
    Duration linger = const Duration(seconds: 60),
    Duration connectTimeout = const Duration(seconds: 10),
    int bufferSize = 32,
    DateTime Function()? clock,
  }) : assert(bufferSize > 0),
       _helper = helper,
       _events = events,
       _log = log,
       _linger = linger,
       _connectTimeout = connectTimeout,
       _bufferSize = bufferSize,
       _clock = clock ?? DateTime.now {
    _helperEvents = helper.events.listen(_onHelperEvent);
  }

  final BluetoothHelper _helper;
  final EventBus _events;
  final AgentLog _log;
  final Duration _linger;
  final Duration _connectTimeout;
  final int _bufferSize;
  final DateTime Function() _clock;
  final Map<String, _Device> _devices = <String, _Device>{};
  late final StreamSubscription<HelperEvent> _helperEvents;
  String? _lastState;
  bool _closed = false;

  /// Meldet Bedarf an: verbindet, falls nötig, und startet das Nachhalten
  /// neu. Liefert die Verbindungsnummer, sobald die Verbindung samt Abos
  /// steht.
  ///
  /// Wirft [BluetoothFailure]: `bluetooth_unreachable` nach
  /// `connectTimeout`, `bluetooth_device_not_found` sofort, wenn der Mac die
  /// Kennung nicht kennt, sonst den Code des Hilfsprogramms (`bluetooth_off`,
  /// `unauthorized`, `bluetooth_unavailable` …).
  Future<int> demand(String deviceId) {
    if (_closed) return Future.error(_closedFailure);
    final d = _device(deviceId);
    d.episode = true;
    _touch(d);
    if (d.ready) return Future.value(d.generation);

    final waiter = _Waiter();
    final existing = d.effort;
    final _Effort effort;
    if (existing == null) {
      effort = _Effort()..waiters.add(waiter);
      _start(d, effort);
    } else {
      effort = existing..waiters.add(waiter);
      // Jeder Aufrufer bekommt sein volles Zeitlimit.
      if (effort.inRound) {
        _armDeadline(d, effort);
      } else {
        _wakeUp(effort);
      }
    }
    waiter.timer = Timer(_connectTimeout, () {
      if (effort.waiters.remove(waiter)) waiter.fail(_unreachable);
    });
    return waiter.completer.future;
  }

  /// Hält die Verbindung: kein Nachhalten läuft ab, und fällt sie, wird neu
  /// verbunden. Verbindet nicht selbst.
  void hold(String deviceId) {
    if (_closed) return;
    final d = _device(deviceId);
    d.episode = true;
    d.holds++;
    d.linger?.cancel();
    d.linger = null;
  }

  /// Gibt ein [hold] frei; beim letzten startet das Nachhalten neu.
  void unhold(String deviceId) {
    final d = _devices[_key(deviceId)];
    if (_closed || d == null || d.holds == 0) return;
    d.holds--;
    if (d.holds > 0) return;
    d.rejoin = false;
    _touch(d);
    final effort = d.effort;
    if (effort != null && effort.waiters.isEmpty) {
      // Ohne Halten und ohne Wartende wird nicht still weiter verbunden.
      if (_cancel(d)) unawaited(_disconnect(d, _reasonNotNeeded));
    }
  }

  /// Trennt die Verbindung (ein halber Auftrag im Gerät verfällt damit) und
  /// verbindet neu, wenn das Gerät gehalten wird; sonst verbindet erst der
  /// nächste [demand]. Abos dieses Bedarfs bleiben erhalten.
  ///
  /// Wirft nie; ein gescheitertes Neuverbinden steht im Log.
  Future<void> reset(String deviceId) async {
    final d = _devices[_key(deviceId)];
    // Ohne Verbindung gibt es nichts zurückzusetzen: eine kommende
    // Verbindung beginnt ohnehin frisch.
    if (_closed || d == null || !d.linked) return;
    _log.info('Bluetooth: Verbindung zu ${d.id} wird zurückgesetzt.');
    await _disconnect(d, _reasonReset);
    if (_closed || d.holds == 0 || d.ready || d.effort != null) return;
    final waiter = _Waiter();
    _start(d, _Effort()..waiters.add(waiter));
    try {
      await waiter.completer.future;
    } on BluetoothFailure catch (failure) {
      _log.info(
        'Bluetooth: ${d.id} nach dem Zurücksetzen nicht verbunden '
        '(${failure.code}).',
      );
    }
  }

  /// Beendet den Bedarf sofort, auch wenn das Gerät gehalten wird: trennt,
  /// verwirft Abos und Puffer. Ein wartender [demand] scheitert mit
  /// `bluetooth_disconnected`.
  Future<void> release(String deviceId) async {
    final d = _devices[_key(deviceId)];
    if (_closed || d == null) return;
    if (d.episode || d.linked || d.effort != null) {
      _log.info('Bluetooth: ${d.id} freigegeben.');
    }
    await _endEpisode(d, _reasonReleased);
  }

  /// Abonniert ein Merkmal; meldet dafür Bedarf an (verbindet also, falls
  /// nötig). Das Abo gilt für diesen Bedarf und wird nach jedem
  /// Neuverbinden wiederhergestellt.
  ///
  /// Wirft [FormatException] bei einer ungültigen UUID, sonst wie [demand]
  /// bzw. mit dem Code des Hilfsprogramms.
  Future<void> subscribe(
    String deviceId,
    String service,
    String characteristic,
  ) async {
    final sub = _Sub(canonicalUuid(service), canonicalUuid(characteristic));
    final d = _device(deviceId);
    await demand(deviceId);
    // Vor dem Aufruf merken: fällt die Verbindung, während er läuft, stellt
    // das Neuverbinden das Abo schon mit her.
    final known = d.subs.containsKey(sub.key);
    d.subs[sub.key] = sub;
    try {
      await _helper.call(HelperOp.subscribe, sub.args(d.id));
    } on BluetoothFailure {
      if (!known) d.subs.remove(sub.key);
      rethrow;
    }
    _log.debug('Bluetooth: ${d.id} abonniert ${sub.characteristic}.');
  }

  /// Beendet ein Abo; ohne Verbindung wird es nur vergessen.
  ///
  /// Wirft [FormatException] bei einer ungültigen UUID.
  Future<void> unsubscribe(
    String deviceId,
    String service,
    String characteristic,
  ) async {
    final sub = _Sub(canonicalUuid(service), canonicalUuid(characteristic));
    final d = _devices[_key(deviceId)];
    if (_closed || d == null) return;
    d.subs.remove(sub.key);
    if (d.episode) _touch(d);
    if (!d.ready) return;
    try {
      await _helper.call(HelperOp.unsubscribe, sub.args(d.id));
    } on BluetoothFailure catch (failure) {
      // Ist die Verbindung weg, ist es das Abo auch.
      if (failure.code != HelperErrorCode.notConnected) rethrow;
    }
  }

  /// Gepufferte Meldungen der laufenden Verbindung, nach `seq` geordnet.
  List<NotificationEntry> notifications(String deviceId) {
    final d = _devices[_key(deviceId)];
    if (d == null) return <NotificationEntry>[];
    return <NotificationEntry>[
      for (final buffer in d.buffers.values)
        for (final entry in buffer)
          if (entry.generation == d.generation) entry,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
  }

  /// Ob die Verbindung samt Abos steht.
  bool isConnected(String deviceId) => _devices[_key(deviceId)]?.ready ?? false;

  /// Nummer der laufenden bzw. letzten Verbindung; 0 vor der ersten.
  int generationOf(String deviceId) =>
      _devices[_key(deviceId)]?.generation ?? 0;

  /// Höchstlängen je Schreibart der stehenden Verbindung, sonst `null`.
  ({int withResponse, int withoutResponse})? maxWriteLength(String deviceId) {
    final d = _devices[_key(deviceId)];
    return d != null && d.ready ? d.maxWrite : null;
  }

  /// Hört auf: wartende Aufrufe scheitern, Zeitgeber enden. Trennt nicht –
  /// mit dem Hilfsprogramm enden auch seine Verbindungen.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final d in _devices.values) {
      d.linger?.cancel();
      d.linger = null;
      final effort = d.effort;
      if (effort != null) {
        _cancel(d);
        _failWaiters(effort, _closedFailure);
      }
    }
    await _helperEvents.cancel();
  }

  // ---------------------------------------------------------------------------
  // Bedarf und Nachhalten

  static String _key(String deviceId) => deviceId.toLowerCase();

  _Device _device(String deviceId) {
    final key = _key(deviceId);
    return _devices.putIfAbsent(key, () => _Device(key));
  }

  /// Startet das Nachhalten neu, außer das Gerät wird gehalten.
  void _touch(_Device d) {
    if (d.holds > 0) return;
    d.linger?.cancel();
    d.linger = Timer(_linger, () {
      d.linger = null;
      if (d.holds > 0) return;
      if (d.linked || d.effort != null) {
        _log.info(
          'Bluetooth: ${d.id} nach ${_linger.inSeconds} s ohne Zugriff '
          'freigegeben.',
        );
      }
      unawaited(_endEpisode(d, _reasonIdle));
    });
  }

  Future<void> _endEpisode(_Device d, String reason) {
    d.episode = false;
    d.holds = 0;
    d.linger?.cancel();
    d.linger = null;
    d.rejoin = false;
    d.subs.clear();
    final effort = d.effort;
    final pending = _cancel(d);
    if (effort != null) _failWaiters(effort, _ended);
    d.buffers.clear();
    if (pending || d.linked) return _disconnect(d, reason);
    return Future<void>.value();
  }

  // ---------------------------------------------------------------------------
  // Verbindungsaufbau

  void _start(_Device d, _Effort effort) {
    d.effort = effort;
    _log.info('Bluetooth: verbinde ${d.id}.');
    unawaited(
      _run(d, effort).catchError((Object error, StackTrace _) {
        _log.error(
          'Bluetooth: Verbindungsaufbau zu ${d.id} gescheitert',
          error,
        );
        if (identical(d.effort, effort)) {
          _cancel(d);
          _failWaiters(effort, _ended);
        }
      }),
    );
  }

  /// Verbindet, bis die Verbindung samt Abos steht, das Zeitlimit reißt oder
  /// niemand mehr wartet.
  Future<void> _run(_Device d, _Effort effort) async {
    // Ein spätes `not_connected` (etwa von einem eben abgebrochenen Versuch)
    // bekommt im selben Zeitlimit einen zweiten Versuch.
    var retried = false;
    _beginRound(d, effort);
    while (true) {
      final failure = await _attempt(d, effort);
      if (effort.cancelled) return;
      if (failure == null) {
        _becomeReady(d, effort);
        return;
      }
      if (failure.code == HelperErrorCode.notConnected && !retried) {
        retried = true;
        continue;
      }

      _endRound(effort);
      _failWaiters(effort, switch (failure.code) {
        HelperErrorCode.unknownDevice => _notFound,
        HelperErrorCode.notConnected => _unreachable,
        _ => failure,
      });
      final radio = _radioCodes.contains(failure.code);
      final helperDown = failure.code == _codeUnavailable;
      if ((!radio && !helperDown) || d.holds == 0) {
        _logFailure(d, failure);
        _cancel(d);
        // Eine halb aufgebaute Verbindung (Abo gescheitert) nicht stehen lassen.
        if (d.linked) unawaited(_disconnect(d, _reasonRestoreFailed));
        return;
      }
      // Gehalten: warten, bis Funk oder Hilfsprogramm wieder da sind.
      _log.info(
        'Bluetooth: ${d.id} wartet auf Bluetooth (${failure.code}), '
        'um neu zu verbinden.',
      );
      await _sleep(effort, helperDown ? _retryPause : null);
      if (effort.cancelled) return;
      retried = false;
      _beginRound(d, effort);
    }
  }

  /// Ein Versuch: verbinden, dann jedes Abo dieses Bedarfs wiederherstellen.
  Future<BluetoothFailure?> _attempt(_Device d, _Effort effort) async {
    try {
      await _helper.call(HelperOp.connect, <String, Object?>{'device': d.id});
    } on BluetoothFailure catch (failure) {
      return failure;
    }
    if (effort.cancelled) return null;
    if (!d.linked) return _linkMissing;
    for (final sub in List<_Sub>.of(d.subs.values)) {
      try {
        await _helper.call(HelperOp.subscribe, sub.args(d.id));
      } on BluetoothFailure catch (failure) {
        if (failure.code != HelperErrorCode.notConnected) {
          // Nie still ohne Abo als verbunden melden: der M110 etwa druckte
          // dann nichts.
          _log.warn(
            'Bluetooth: Abo ${sub.characteristic} auf ${d.id} nicht '
            'wiederhergestellt (${failure.code}).',
          );
        }
        return failure;
      }
      if (effort.cancelled) return null;
      if (!d.linked) return _linkMissing;
    }
    return null;
  }

  void _becomeReady(_Device d, _Effort effort) {
    _endRound(effort);
    d.effort = null;
    d.ready = true;
    d.rejoin = false;
    final max = d.maxWrite;
    _log.info(
      'Bluetooth: ${d.id} verbunden (Verbindung ${d.generation}'
      '${max == null ? '' : ', schreibt bis ${max.withResponse}/'
                '${max.withoutResponse} Byte'}'
      '${d.subs.isEmpty ? '' : ', ${d.subs.length} Abo(s)'}).',
    );
    _events.publish(eventBluetoothDevice, <String, Object?>{
      'id': d.id,
      'connected': true,
      'generation': d.generation,
    });
    // Was während des Wiederherstellens kam, erst nach der Verbindungsnummer.
    for (final entry in notifications(d.id)) {
      _publishNotification(d, entry);
    }
    final waiters = List<_Waiter>.of(effort.waiters);
    effort.waiters.clear();
    for (final waiter in waiters) {
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(d.generation);
      }
    }
  }

  void _beginRound(_Device d, _Effort effort) {
    effort.inRound = true;
    _armDeadline(d, effort);
  }

  void _armDeadline(_Device d, _Effort effort) {
    effort.deadline?.cancel();
    effort.deadline = Timer(_connectTimeout, () {
      if (effort.cancelled || !identical(d.effort, effort)) return;
      _log.warn(
        'Bluetooth: ${d.id} nach ${_connectTimeout.inSeconds} s nicht '
        'erreichbar; Verbindungsaufbau abgebrochen.',
      );
      // CoreBluetooth wartet ohne Ende; das offene `connect` bekommt nach dem
      // Trennen ein `not_connected`, das hier niemand mehr erwartet.
      _cancel(d);
      _failWaiters(effort, _unreachable);
      unawaited(_disconnect(d, _reasonTimeout));
    });
  }

  void _endRound(_Effort effort) {
    effort.inRound = false;
    effort.deadline?.cancel();
    effort.deadline = null;
  }

  Future<void> _sleep(_Effort effort, Duration? retry) {
    final wake = effort.wake = Completer<void>();
    if (retry != null) effort.retry = Timer(retry, () => _wakeUp(effort));
    return wake.future;
  }

  void _wakeUp(_Effort effort) {
    effort.retry?.cancel();
    effort.retry = null;
    final wake = effort.wake;
    effort.wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Beendet den laufenden Verbindungsaufbau (Wartende bleiben stehen).
  /// Liefert, ob dabei ein `connect` oder ein Wiederherstellen offen war.
  bool _cancel(_Device d) {
    final effort = d.effort;
    if (effort == null) return false;
    d.effort = null;
    final pending = effort.inRound;
    effort.cancelled = true;
    _endRound(effort);
    _wakeUp(effort);
    return pending;
  }

  void _failWaiters(_Effort effort, BluetoothFailure failure) {
    final waiters = List<_Waiter>.of(effort.waiters);
    effort.waiters.clear();
    for (final waiter in waiters) {
      waiter.fail(failure);
    }
  }

  void _logFailure(_Device d, BluetoothFailure failure) {
    switch (failure.code) {
      case HelperErrorCode.unknownDevice:
        _log.warn('Bluetooth: dieser Mac kennt ${d.id} nicht (mehr).');
      case HelperErrorCode.notConnected:
        _log.warn('Bluetooth: ${d.id} trennt beim Verbinden immer wieder.');
      default:
        _log.info('Bluetooth: ${d.id} nicht verbunden (${failure.code}).');
    }
  }

  /// Trennt; ein `disconnected` dieser Verbindung gilt dann als gewollt.
  Future<void> _disconnect(_Device d, String reason) async {
    final generation = d.generation;
    d.closing = (generation: generation, reason: reason);
    try {
      await _helper.call(HelperOp.disconnect, <String, Object?>{
        'device': d.id,
      });
    } on Object catch (error) {
      _log.debug('Bluetooth: Trennen von ${d.id}: $error');
    }
    // Kam kein `disconnected` (Hilfsprogramm weg), trotzdem als getrennt
    // führen – aber nie eine inzwischen neue Verbindung.
    if (d.linked && d.generation == generation) _lost(d, reason);
    if (d.closing?.generation == generation) d.closing = null;
  }

  // ---------------------------------------------------------------------------
  // Ereignisse des Hilfsprogramms

  void _onHelperEvent(HelperEvent event) {
    if (_closed) return;
    final data = event.data;
    if (event.event == HelperEventName.state) {
      final state = data['state'];
      if (state is String) _onState(state);
      return;
    }
    final device = data['device'];
    if (device is! String) return;
    final d = _devices[_key(device)];
    if (d == null) return;
    switch (event.event) {
      case HelperEventName.connected:
        _onConnected(d, data);
      case HelperEventName.disconnected:
        final reason = data['reason'];
        _lost(d, reason is String ? reason : 'disconnected');
      case HelperEventName.notification:
        _onNotification(d, data);
    }
  }

  void _onState(String state) {
    if (state != _lastState) {
      _lastState = state;
      _events.publish(eventBluetoothState, <String, Object?>{'state': state});
    }
    // Wer auf Funk oder Hilfsprogramm wartet, versucht es jetzt; bei einem
    // Neustart startet erst ein Aufruf das Hilfsprogramm wieder.
    if (state == 'poweredOn' || state == helperStateRestarting) {
      for (final d in _devices.values) {
        final effort = d.effort;
        if (effort != null && effort.wake != null) _wakeUp(effort);
      }
    }
    // macOS meldet die Trennung oft vor `poweredOff`: der Versuch in dieser
    // Lücke scheitert mit `not_connected` und gibt auf. Ein gehaltenes Gerät
    // ohne Versuch verbindet deshalb mit dem Funk wieder still neu.
    if (state == 'poweredOn') {
      for (final d in _devices.values) {
        if (d.rejoin && d.holds > 0 && d.effort == null && !d.ready) {
          _log.info('Bluetooth: ${d.id} wird gehalten, verbinde neu.');
          _start(d, _Effort());
        }
      }
    }
  }

  void _onConnected(_Device d, Map<String, Object?> data) {
    final withResponse = data['maxWriteWithResponse'];
    final withoutResponse = data['maxWriteWithoutResponse'];
    final max = withResponse is int && withoutResponse is int
        ? (withResponse: withResponse, withoutResponse: withoutResponse)
        : null;
    if (d.linked) {
      // Erneutes `connected` derselben Verbindung: keine neue Nummer.
      if (max != null) d.maxWrite = max;
      return;
    }
    d.linked = true;
    d.generation++;
    d.maxWrite = max;
    d.buffers.clear();
    final effort = d.effort;
    if (effort == null || !effort.inRound) {
      // Etwa ein abgebrochener Versuch, der doch noch zustande kam.
      _log.info('Bluetooth: ${d.id} ungefragt verbunden; wird getrennt.');
      unawaited(_disconnect(d, _reasonUnrequested));
    }
  }

  /// Die Verbindung ist weg (gemeldet oder angenommen).
  void _lost(_Device d, String helperReason) {
    if (!d.linked) return;
    final closing = d.closing;
    final ours = closing != null && closing.generation == d.generation
        ? closing.reason
        : null;
    final reason = ours ?? helperReason;
    final wasReady = d.ready;
    d.linked = false;
    d.ready = false;
    d.maxWrite = null;
    d.buffers.clear();
    if (!wasReady) return;

    _log.info('Bluetooth: ${d.id} getrennt ($reason).');
    _events.publish(eventBluetoothDevice, <String, Object?>{
      'id': d.id,
      'connected': false,
      'generation': d.generation,
      'reason': reason,
    });
    d.rejoin = ours == null && d.holds > 0;
    if (ours == null && d.holds > 0 && d.effort == null && !_closed) {
      _log.info('Bluetooth: ${d.id} wird gehalten, verbinde neu.');
      _start(d, _Effort());
    }
  }

  void _onNotification(_Device d, Map<String, Object?> data) {
    if (!d.linked) return;
    final service = data['service'];
    final characteristic = data['characteristic'];
    final payload = data['data'];
    if (service is! String || characteristic is! String || payload is! String) {
      _log.warn('Bluetooth: unvollständige Meldung von ${d.id} verworfen.');
      return;
    }
    final NotificationEntry entry;
    try {
      entry = NotificationEntry(
        service: canonicalUuid(service),
        characteristic: canonicalUuid(characteristic),
        data: base64Decode(payload),
        at: _clock(),
        generation: d.generation,
        seq: d.seq + 1,
      );
    } on FormatException {
      _log.warn('Bluetooth: unlesbare Meldung von ${d.id} verworfen.');
      return;
    }
    d.seq = entry.seq;
    final buffer = d.buffers.putIfAbsent(
      '${entry.service}|${entry.characteristic}',
      ListQueue<NotificationEntry>.new,
    )..addLast(entry);
    while (buffer.length > _bufferSize) {
      buffer.removeFirst();
    }

    final bytes = entry.data;
    // Längere Meldungen nie mit Inhalt: sie könnten Nutzdaten tragen.
    final inhalt = bytes.length <= _logBytes
        ? ': ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}'
        : '';
    _log.debug(
      'Bluetooth: Meldung von ${d.id} auf ${entry.characteristic} '
      '(${bytes.length} Byte$inhalt).',
    );
    // Solange die Abos wiederhergestellt werden, ist die Verbindung noch nicht
    // gemeldet; diese Meldungen gehen danach hinaus.
    if (d.ready) _publishNotification(d, entry);
  }

  void _publishNotification(_Device d, NotificationEntry entry) {
    _events.publish(eventBluetoothNotification, <String, Object?>{
      'id': d.id,
      'service': entry.service,
      'characteristic': entry.characteristic,
      'data': base64Encode(entry.data),
      'generation': entry.generation,
      'seq': entry.seq,
    });
  }
}

/// Stand eines Geräts; bleibt bestehen, solange der Agent läuft (Nummern
/// zählen weiter).
class _Device {
  _Device(this.id);

  final String id;

  /// Ein Bedarf läuft (bis [BluetoothConnections.release] oder zum Ende des
  /// Nachhaltens); an ihm hängen die Abos.
  bool episode = false;
  int holds = 0;
  Timer? linger;

  /// Die gehaltene Verbindung ist ohne unser Zutun gefallen und noch nicht
  /// wieder da: mit dem Funk (`poweredOn`) wird still neu verbunden.
  bool rejoin = false;

  /// Das Hilfsprogramm hat eine Verbindung (`connected` ohne
  /// `disconnected`).
  bool linked = false;

  /// Verbindung samt Abos steht und ist gemeldet.
  bool ready = false;

  int generation = 0;
  int seq = 0;
  ({int withResponse, int withoutResponse})? maxWrite;

  /// Abos dieses Bedarfs.
  final Map<String, _Sub> subs = <String, _Sub>{};

  /// Meldungen der laufenden Verbindung je Dienst und Merkmal.
  final Map<String, ListQueue<NotificationEntry>> buffers =
      <String, ListQueue<NotificationEntry>>{};

  /// Ein selbst angestoßenes Trennen dieser Verbindung samt Grund.
  ({int generation, String reason})? closing;

  _Effort? effort;
}

class _Sub {
  _Sub(this.service, this.characteristic);

  final String service;
  final String characteristic;

  String get key => '$service|$characteristic';

  Map<String, Object?> args(String device) => <String, Object?>{
    'device': device,
    'service': service,
    'characteristic': characteristic,
  };
}

/// Ein laufender Verbindungsaufbau (geteilt von allen Wartenden).
class _Effort {
  final List<_Waiter> waiters = <_Waiter>[];
  bool cancelled = false;

  /// Ein `connect` bzw. das Wiederherstellen der Abos läuft.
  bool inRound = false;
  Timer? deadline;

  /// Gesetzt, solange auf Funk oder Hilfsprogramm gewartet wird.
  Completer<void>? wake;
  Timer? retry;
}

class _Waiter {
  final Completer<int> completer = Completer<int>();
  Timer? timer;

  void fail(BluetoothFailure failure) {
    timer?.cancel();
    if (!completer.isCompleted) completer.completeError(failure);
  }
}
