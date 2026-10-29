/// Belegung je Gerät: ein Druck ist eine Folge von Schreibvorgängen (Stand
/// prüfen → Pakete → auf „fertig“ warten), und zwei Tabs dürfen sich dabei
/// nie mischen.
///
/// Gerätewissen gibt es hier keines. Was beim Beginn und Ende einer Belegung
/// mit der Verbindung geschieht (halten, freigeben, zurücksetzen), hängt die
/// Brücke über die Rückrufe an.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'helper.dart';

const String _codeBusy = 'bluetooth_busy';
const String _codeUnavailable = 'bluetooth_unavailable';

/// Zufallsbytes einer Belegungs-ID.
const int _idBytes = 16;

const BluetoothFailure _busy = BluetoothFailure(
  _codeBusy,
  'Das Gerät ist von einem anderen Druck belegt.',
);

const BluetoothFailure _closedFailure = BluetoothFailure(
  _codeUnavailable,
  'Bluetooth ist beendet.',
);

/// Eine Belegung eines Geräts.
class Lease {
  Lease({required this.id, required this.deviceId, required this.expiresAt});

  /// Zufällige Kennung (16 Byte, base64url ohne Polster); wer sie kennt,
  /// darf auf das Gerät schreiben.
  final String id;

  final String deviceId;

  /// Bis dahin muss die Belegung erneuert werden, sonst endet sie abnorm.
  DateTime expiresAt;
}

/// Belegungen je Gerät.
///
/// * **Belegen:** höchstens eine Belegung je Gerät. [acquire] auf ein freies
///   Gerät gibt sie sofort; sonst wartet der Aufruf in Reihenfolge höchstens
///   `wait` und scheitert dann mit `bluetooth_busy`.
/// * **Ablauf:** eine Belegung gilt [ttl] ab Beginn bzw. letzter Erneuerung
///   ([renew]). So verliert ein geschlossener oder neu geladener Tab sie nach
///   kurzer Zeit, ohne dass Connect ihn kennen muss.
/// * **Freigabe:** [release] beendet normal – `onEnded`, und der Nächste in
///   der Warteschlange kommt sofort dran.
/// * **Abnormes Ende:** läuft eine Belegung ab, kommt erst `onAbnormalEnd`
///   (die Brücke setzt die Verbindung zurück, damit kein halber Auftrag im
///   Gerät bleibt), dann `onEnded`. Der Nächste kommt erst dran, wenn
///   `onAbnormalEnd` fertig ist – sonst schriebe er in die Verbindung, die
///   gerade getrennt wird. Ein Fehler darin hält die Übergabe nicht auf.
/// * **Uhr und Zeitgeber:** abgelaufen ist eine Belegung auch, wenn die Uhr
///   den Ablauf überschritten hat, der Zeitgeber aber noch nicht gelaufen ist –
///   im Ruhezustand können Zeitgeber stehen, die Uhr läuft weiter. Jede
///   Belegung endet genau einmal, gleich wer den Ablauf zuerst bemerkt.
///
/// Jedes `onAcquired` bekommt genau ein `onEnded`, auch bei [close].
/// Rückrufe, die werfen, ändern am Ablauf nichts.
class DeviceLeases {
  DeviceLeases({
    required FutureOr<void> Function(String deviceId) onAbnormalEnd,
    void Function(String deviceId)? onAcquired,
    void Function(String deviceId)? onEnded,
    this.ttl = const Duration(seconds: 5),
    DateTime Function()? clock,
    Random? random,
  }) : _onAbnormalEnd = onAbnormalEnd,
       _onAcquired = onAcquired,
       _onEnded = onEnded,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// Laufzeit einer Belegung ohne Erneuerung.
  final Duration ttl;

  final FutureOr<void> Function(String deviceId) _onAbnormalEnd;
  final void Function(String deviceId)? _onAcquired;
  final void Function(String deviceId)? _onEnded;
  final DateTime Function() _clock;
  final Random _random;

  final Map<String, _Slot> _slots = <String, _Slot>{};
  bool _closed = false;

  /// Belegt das Gerät; wartet dafür höchstens [wait], sonst
  /// `bluetooth_busy`. Nach [close] `bluetooth_unavailable`.
  Future<Lease> acquire(
    String deviceId, {
    Duration wait = const Duration(seconds: 30),
  }) {
    if (_closed) return Future<Lease>.error(_closedFailure);
    final key = _key(deviceId);
    final slot = _slots.putIfAbsent(key, () => _Slot(key));
    final holder = slot.holder;
    if (holder != null && _overdue(holder)) _expire(slot, holder);
    if (slot.free) return Future<Lease>.value(_grant(slot, deviceId));

    final waiter = _Waiter(deviceId);
    waiter.timer = Timer(wait, () {
      // Wer nicht mehr wartet, bekommt die Belegung auch später nicht.
      if (slot.waiters.remove(waiter)) waiter.completer.completeError(_busy);
    });
    slot.waiters.add(waiter);
    return waiter.completer.future;
  }

  /// Verlängert die Belegung um [ttl]; `false`, wenn [leaseId] das Gerät
  /// nicht (mehr) belegt.
  bool renew(String deviceId, String leaseId) {
    final slot = _held(deviceId, leaseId);
    if (slot == null) return false;
    final lease = slot.holder!..expiresAt = _clock().add(ttl);
    _arm(slot, lease);
    return true;
  }

  /// Gibt die Belegung frei (normales Ende); `false`, wenn [leaseId] das
  /// Gerät nicht (mehr) belegt.
  bool release(String deviceId, String leaseId) {
    final slot = _held(deviceId, leaseId);
    if (slot == null) return false;
    final lease = slot.holder!;
    slot.expiry?.cancel();
    slot.expiry = null;
    slot.holder = null;
    _notify(_onEnded, lease.deviceId);
    _grantNext(slot);
    return true;
  }

  /// Ob [leaseId] das Gerät gerade belegt.
  bool holds(String deviceId, String leaseId) =>
      _held(deviceId, leaseId) != null;

  /// Hört auf: Wartende scheitern mit `bluetooth_unavailable`, laufende
  /// Belegungen enden normal (die Verbindungen enden mit dem Agenten), und
  /// es wird nichts mehr vergeben.
  void close() {
    if (_closed) return;
    _closed = true;
    final slots = List<_Slot>.of(_slots.values);
    _slots.clear();
    for (final slot in slots) {
      for (final waiter in slot.waiters) {
        waiter.timer?.cancel();
        waiter.completer.completeError(_closedFailure);
      }
      slot.waiters.clear();
      final lease = slot.holder;
      if (lease == null) continue;
      slot.expiry?.cancel();
      slot.expiry = null;
      slot.holder = null;
      _notify(_onEnded, lease.deviceId);
    }
  }

  // ---------------------------------------------------------------------------

  static String _key(String deviceId) => deviceId.toLowerCase();

  bool _overdue(Lease lease) => !_clock().isBefore(lease.expiresAt);

  /// Der Platz des Geräts, wenn [leaseId] es gerade belegt. Ist die Belegung
  /// nach der Uhr schon abgelaufen, endet sie hier.
  _Slot? _held(String deviceId, String leaseId) {
    final slot = _slots[_key(deviceId)];
    final lease = slot?.holder;
    if (slot == null || lease == null || lease.id != leaseId) return null;
    if (_overdue(lease)) {
      _expire(slot, lease);
      return null;
    }
    return slot;
  }

  Lease _grant(_Slot slot, String deviceId) {
    final lease = Lease(
      id: _newId(),
      deviceId: deviceId,
      expiresAt: _clock().add(ttl),
    );
    slot.holder = lease;
    _arm(slot, lease);
    _notify(_onAcquired, deviceId);
    return lease;
  }

  void _arm(_Slot slot, Lease lease) {
    slot.expiry?.cancel();
    slot.expiry = Timer(ttl, () => _expire(slot, lease));
  }

  void _expire(_Slot slot, Lease lease) {
    // Zeitgeber und Uhr können denselben Ablauf bemerken; er zählt einmal.
    if (!identical(slot.holder, lease)) return;
    slot.expiry?.cancel();
    slot.expiry = null;
    slot.holder = null;
    slot.ending = true;
    unawaited(_endAbnormally(slot, lease.deviceId));
  }

  Future<void> _endAbnormally(_Slot slot, String deviceId) async {
    try {
      await _onAbnormalEnd(deviceId);
    } catch (_) {
      // Ein gescheitertes Zurücksetzen darf das Gerät nicht blockieren.
    }
    slot.ending = false;
    _notify(_onEnded, deviceId);
    _grantNext(slot);
  }

  void _grantNext(_Slot slot) {
    if (_closed || slot.holder != null || slot.ending) return;
    if (slot.waiters.isEmpty) {
      if (identical(_slots[slot.key], slot)) _slots.remove(slot.key);
      return;
    }
    final waiter = slot.waiters.removeFirst();
    waiter.timer?.cancel();
    waiter.completer.complete(_grant(slot, waiter.deviceId));
  }

  void _notify(void Function(String deviceId)? callback, String deviceId) {
    try {
      callback?.call(deviceId);
    } catch (_) {
      // Ein Fehler der Brücke darf Belegung und Warteschlange nicht
      // durcheinanderbringen.
    }
  }

  String _newId() {
    final bytes = List<int>.generate(_idBytes, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

/// Belegung und Warteschlange eines Geräts.
class _Slot {
  _Slot(this.key);

  final String key;
  Lease? holder;
  Timer? expiry;

  /// Ein abnormes Ende läuft (`onAbnormalEnd` noch nicht fertig).
  bool ending = false;

  final Queue<_Waiter> waiters = Queue<_Waiter>();

  bool get free => holder == null && !ending && waiters.isEmpty;
}

class _Waiter {
  _Waiter(this.deviceId);

  final String deviceId;
  final Completer<Lease> completer = Completer<Lease>();
  Timer? timer;
}
