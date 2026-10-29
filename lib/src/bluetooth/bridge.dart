/// Die Bluetooth-Brücke, so wie die lokale API sie anspricht: Zulassung,
/// Sperrliste, Verbindungen bei Bedarf, Belegung und Schreiben – mit festen
/// Fehlercodes und deutschem Klartext.
///
/// Gerätewissen gibt es hier keines: Bytes gehen unverändert hinaus und
/// kommen unverändert zurück.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../config/model.dart';
import '../config/store.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import 'blocklist.dart';
import 'connections.dart';
import 'helper.dart';
import 'leases.dart';
import 'protocol.dart';
import 'uuids.dart';

/// Bluetooth gibt es auf diesem Rechner nicht (bisher nur macOS).
const String errorBluetoothUnsupported = 'bluetooth_unsupported';

/// macOS hat Connect die Bluetooth-Freigabe nicht erteilt.
const String errorBluetoothUnauthorized = 'bluetooth_unauthorized';

/// Bluetooth ist am Mac ausgeschaltet.
const String errorBluetoothOff = 'bluetooth_off';

/// Das Hilfsprogramm ist gerade nicht da oder antwortet nicht brauchbar.
const String errorBluetoothUnavailable = 'bluetooth_unavailable';

/// Das Gerät ist nicht zugelassen.
const String errorBluetoothDeviceUnknown = 'bluetooth_device_unknown';

/// Der Mac kennt die Kennung nicht (mehr).
const String errorBluetoothDeviceNotFound = 'bluetooth_device_not_found';

/// Verbindungsaufbau nach dem Zeitlimit abgebrochen.
const String errorBluetoothUnreachable = 'bluetooth_unreachable';

/// Dienst oder Merkmal steht auf der Sperrliste.
const String errorBluetoothBlocked = 'bluetooth_blocked';

/// Das Merkmal gibt es auf dem Gerät nicht.
const String errorBluetoothCharacteristicUnknown =
    'bluetooth_characteristic_unknown';

/// Das Merkmal kann das Verlangte nicht (lesen, Schreibart, Abo).
const String errorBluetoothOperationUnsupported =
    'bluetooth_operation_unsupported';

/// Schreiben ohne gültige Belegung.
const String errorBluetoothLeaseRequired = 'bluetooth_lease_required';

/// Die Belegung kam in der Wartezeit nicht frei.
const String errorBluetoothBusy = 'bluetooth_busy';

/// Ein Paket ist länger als die Höchstlänge der gewählten Schreibart.
const String errorBluetoothWriteTooLong = 'bluetooth_write_too_long';

/// Das Gerät hat einen Schreibvorgang nicht angenommen.
const String errorBluetoothWriteFailed = 'bluetooth_write_failed';

/// Die Verbindung ist weg (auch: eine neue Verbindungsnummer).
const String errorBluetoothDisconnected = 'bluetooth_disconnected';

/// Schon so viele Geräte zugelassen, wie Connect sich merkt.
const String errorBluetoothTooManyDevices = 'bluetooth_too_many_devices';

/// Höchstzahl zugelassener Geräte.
const int maxBluetoothDevices = 16;

/// Deutscher Klartext je Fehlercode; die Kasse zeigt ihn unverändert an.
const Map<String, String> bluetoothErrorMessages = <String, String>{
  errorBluetoothUnsupported:
      'Bluetooth gibt es in Kasseneck Connect bisher nur am Mac.',
  errorBluetoothUnauthorized:
      'Kasseneck Connect darf Bluetooth nicht verwenden – bitte in den '
      'Systemeinstellungen unter Datenschutz & Sicherheit → Bluetooth '
      'erlauben.',
  errorBluetoothOff: 'Bluetooth ist am Mac ausgeschaltet.',
  errorBluetoothUnavailable:
      'Bluetooth ist gerade nicht bereit – bitte gleich noch einmal '
      'versuchen.',
  errorBluetoothDeviceUnknown:
      'Dieses Gerät ist in Kasseneck Connect nicht zugelassen – bitte zuerst '
      'auswählen.',
  errorBluetoothDeviceNotFound:
      'Dieser Mac kennt das Gerät nicht mehr – bitte neu suchen.',
  errorBluetoothUnreachable:
      'Nicht erreichbar – vielleicht mit einem anderen Gerät verbunden.',
  errorBluetoothBlocked:
      'Auf diesen Dienst darf die Kasse aus Sicherheitsgründen nicht '
      'zugreifen.',
  errorBluetoothCharacteristicUnknown:
      'Dieses Merkmal gibt es auf dem Gerät nicht.',
  errorBluetoothOperationUnsupported:
      'Das Gerät kann das bei diesem Merkmal nicht.',
  errorBluetoothLeaseRequired:
      'Schreiben geht nur mit gültiger Belegung – bitte das Gerät neu '
      'belegen.',
  errorBluetoothBusy: 'Das Gerät ist von einem anderen Druck belegt.',
  errorBluetoothWriteTooLong:
      'Ein Paket ist länger, als das Gerät auf einmal annimmt.',
  errorBluetoothWriteFailed: 'Das Gerät hat das Schreiben nicht bestätigt.',
  errorBluetoothDisconnected: 'Die Verbindung zum Gerät wurde getrennt.',
  errorBluetoothTooManyDevices:
      'Es sind schon 16 Geräte zugelassen – bitte zuerst eines vergessen.',
};

/// Codes des Hilfsprogramms, die als Code der Brücke hinausgehen.
const Map<String, String> _helperCodes = <String, String>{
  HelperErrorCode.unknownDevice: errorBluetoothDeviceNotFound,
  HelperErrorCode.notConnected: errorBluetoothDisconnected,
  HelperErrorCode.unknownCharacteristic: errorBluetoothCharacteristicUnknown,
  HelperErrorCode.unsupportedOperation: errorBluetoothOperationUnsupported,
  HelperErrorCode.writeFailed: errorBluetoothWriteFailed,
  HelperErrorCode.bluetoothOff: errorBluetoothOff,
  HelperErrorCode.unauthorized: errorBluetoothUnauthorized,
  HelperErrorCode.bluetoothUnsupported: errorBluetoothUnsupported,
};

/// Suchdauer: Vorgabe und Grenzen.
const Duration _scanDefault = Duration(seconds: 4);
const Duration _scanMin = Duration(seconds: 1);
const Duration _scanMax = Duration(seconds: 10);

/// Längste Wartezeit auf eine Belegung.
const Duration _leaseWaitMax = Duration(seconds: 30);

/// Höchstlängen, wenn das Hilfsprogramm keine gemeldet hat: ohne Antwort die
/// kleinste MTU (23) abzüglich Kopf, mit Antwort die größte Attributlänge.
const ({int withResponse, int withoutResponse}) _fallbackMaxWrite = (
  withResponse: 512,
  withoutResponse: 20,
);

/// Ein Fehler der Brücke mit dem Klartext seines Codes.
BluetoothFailure _failure(String code, {Object? detail}) =>
    BluetoothFailure(code, bluetoothErrorMessages[code]!, detail: detail);

/// Die Brücke für die Bluetooth-Endpunkte.
///
/// * **Zulassung:** außer [scan], [approve], [summary] und [forget] wirkt
///   jeder Gerätezugriff nur auf Kennungen aus `config.json`; sonst
///   `bluetooth_device_unknown`, bevor Bluetooth überhaupt berührt wird.
/// * **Sperrliste:** gesperrte Dienste und Merkmale (`blocklist.dart`) fehlen
///   in [gatt]; lesen, schreiben und abonnieren weist die Brücke mit
///   `bluetooth_blocked` ab.
/// * **Belegung:** [write] nur mit gültiger Belegung, und jedes Schreiben
///   erneuert sie. Eine Belegung hält die Verbindung; endet sie, ohne
///   freigegeben zu sein, wird die Verbindung zurückgesetzt, damit kein
///   halber Auftrag im Gerät hängt.
/// * **Fehler:** alles, was hinausgeht, ist ein [BluetoothFailure] mit einem
///   Code aus [bluetoothErrorMessages] und dessen Klartext. Ungültige UUIDs
///   oder Kennungen ergeben eine [FormatException] (Sache der Route).
///
/// Bluetooth startet erst mit dem ersten Zugriff auf ein Gerät bzw. mit der
/// ersten Suche; [summary] berührt es nie (`/v1/status` fragt sie bei jedem
/// Laden der Kasse).
class BluetoothBridge {
  /// [connections] und [leases] sind für Tests austauschbar. Wer [leases]
  /// selbst baut, hängt die Rückrufe selbst an die Verbindungen (`hold`,
  /// `unhold`, `reset`) und gibt beiden dieselbe Uhr. Ohne sie baut die
  /// Brücke beide mit [clock].
  BluetoothBridge({
    required ConfigStore store,
    required AgentLog log,
    required EventBus events,
    required BluetoothHelper helper,
    BluetoothConnections? connections,
    DeviceLeases? leases,
    DateTime Function()? clock,
  }) : _store = store,
       _log = log,
       _helper = helper,
       _clock = clock ?? DateTime.now {
    _connections =
        connections ??
        BluetoothConnections(
          helper: helper,
          events: events,
          log: log,
          clock: _clock,
        );
    _leases =
        leases ??
        DeviceLeases(
          onAcquired: _connections.hold,
          onEnded: _leaseEnded,
          onAbnormalEnd: _leaseAbandoned,
          clock: _clock,
        );
  }

  final ConfigStore _store;
  final AgentLog _log;
  final BluetoothHelper _helper;
  final DateTime Function() _clock;
  late final BluetoothConnections _connections;
  late final DeviceLeases _leases;

  /// Geräte, die gerade vergessen werden: ab dem ersten Schritt gesperrt,
  /// auch solange sie noch in der Datei stehen.
  final Set<String> _forgetting = <String>{};

  /// Laufende Suche; gleichzeitige Aufrufe bekommen dasselbe Ergebnis.
  Future<List<Map<String, Object?>>>? _scan;

  /// Namen aus der letzten Suche, für [approve] ohne Namen.
  Map<String, String> _scanNames = <String, String>{};

  /// Letzter Schreibvorgang je Gerät; der nächste wartet auf ihn.
  final Map<String, Future<void>> _writing = <String, Future<void>>{};

  /// Ob es auf diesem Rechner ein Hilfsprogramm gibt.
  bool get available => _helper is! UnsupportedBluetoothHelper;

  /// Funkzustand bzw. Zustand des Hilfsprogramms (`unknown` vor dem ersten
  /// Zugriff, `starting`, `helper_restarting`, `poweredOn` …).
  String get state => _helper.state;

  /// Laufzeit einer Belegung ohne Erneuerung.
  Duration get leaseTtl => _leases.ttl;

  /// Zustand und zugelassene Geräte mit Verbindungsstand. Berührt Bluetooth
  /// nicht.
  Future<Map<String, Object?>> summary() async {
    final config = await _store.load();
    return <String, Object?>{
      'state': state,
      'devices': <Map<String, Object?>>[
        for (final device in config.bluetoothDevices)
          if (!_forgetting.contains(device.id)) _deviceJson(device),
      ],
    };
  }

  /// Sucht [duration] lang (1–10 s) nach Geräten; läuft schon eine Suche,
  /// bekommt der Aufruf deren Ergebnis. Je Gerät ein Eintrag
  /// `{id, name, rssi, services, approved}` in der Reihenfolge des Fundes;
  /// ein späterer Fund desselben Geräts ergänzt Name und Signal.
  Future<List<Map<String, Object?>>> scan({Duration duration = _scanDefault}) {
    if (!available) return Future.error(_failure(errorBluetoothUnsupported));
    final running = _scan;
    if (running != null) return running;
    final clamped = duration < _scanMin
        ? _scanMin
        : (duration > _scanMax ? _scanMax : duration);
    // Freigeben, bevor jemand das Ergebnis sieht: wer gleich wieder sucht,
    // bekommt eine neue Suche, nicht die alte.
    return _scan = _runScan(clamped).whenComplete(() => _scan = null);
  }

  /// Lässt ein Gerät zu (höchstens [maxBluetoothDevices]). Name: [name],
  /// sonst der aus der letzten Suche, sonst der gespeicherte, sonst die
  /// Kennung. Ein schon zugelassenes Gerät behält seinen Zeitpunkt.
  ///
  /// Wirft [FormatException] bei einer ungültigen Kennung.
  Future<Map<String, Object?>> approve(String id, {String? name}) async {
    _requireAvailable();
    if (!isValidDeviceId(id)) {
      throw FormatException('Keine gültige Gerätekennung', id);
    }
    final key = id.toLowerCase();
    final given = name?.trim();
    final chosen = given != null && given.isNotEmpty ? given : _scanNames[key];
    late BluetoothDeviceConfig approved;
    var neu = false;
    await _store.mutate((config) {
      final devices = List<BluetoothDeviceConfig>.of(config.bluetoothDevices);
      final index = devices.indexWhere((d) => d.id == key);
      if (index >= 0) {
        final old = devices[index];
        approved = BluetoothDeviceConfig(
          id: key,
          name: chosen ?? old.name,
          approvedAt: old.approvedAt,
        );
        devices[index] = approved;
      } else {
        if (devices.length >= maxBluetoothDevices) {
          throw _failure(errorBluetoothTooManyDevices);
        }
        neu = true;
        approved = BluetoothDeviceConfig(
          id: key,
          name: chosen ?? key,
          approvedAt: _clock().toUtc(),
        );
        devices.add(approved);
      }
      return config.copyWith(bluetoothDevices: devices);
    });
    _log.info('Bluetooth: $key ${neu ? 'zugelassen' : 'erneut zugelassen'}.');
    return _deviceJson(approved);
  }

  /// Vergisst ein Gerät: beendet seine Belegung (Wartende scheitern mit
  /// `bluetooth_device_unknown`), trennt und entfernt es aus der
  /// Konfiguration. `false`, wenn es nicht zugelassen war.
  Future<bool> forget(String id) async {
    final key = id.toLowerCase();
    _forgetting.add(key);
    try {
      // Die Belegung endet normal (ohne Zurücksetzen): getrennt wird gleich
      // ohnehin, und das Halten ist danach ausgeglichen.
      _leases.revoke(key);
      await _connections.release(key);
      var removed = false;
      await _store.mutate((config) {
        final devices = config.bluetoothDevices
            .where((d) => d.id != key)
            .toList();
        removed = devices.length != config.bluetoothDevices.length;
        return removed ? config.copyWith(bluetoothDevices: devices) : config;
      });
      if (removed) _log.info('Bluetooth: $key vergessen.');
      return removed;
    } finally {
      _forgetting.remove(key);
    }
  }

  /// Meldet Bedarf an (verbindet bzw. verlängert das Nachhalten) und liefert
  /// die Verbindungsnummer.
  Future<int> connect(String id) =>
      _onDevice(id, (key) => _connections.demand(key));

  /// Beendet den Bedarf sofort: trennt, verwirft Abos und Meldungen.
  ///
  /// Solange das Gerät belegt ist (oder nach einem Ablauf zurückgesetzt
  /// wird), `bluetooth_busy`: sonst kappte ein anderer Tab einen laufenden
  /// Druck, und das Halten der Belegung fiele mit weg – der Nächste in der
  /// Warteschlange bekäme ein Gerät, das weder still neu verbindet noch vor
  /// dem Nachhalten sicher ist.
  Future<void> release(String id) => _onDevice(id, (key) {
    if (_leases.isHeld(key)) throw _failure(errorBluetoothBusy);
    return _connections.release(key);
  });

  /// Dienste und Merkmale mit Eigenschaften; Gesperrtes fehlt.
  Future<List<Map<String, Object?>>> gatt(String id) =>
      _onDevice(id, (key) async {
        await _connections.demand(key);
        final result = await _helper.call(HelperOp.gatt, <String, Object?>{
          'device': key,
        });
        final services = result['services'];
        if (services is! List) throw _unreadable(key, HelperOp.gatt);
        return <Map<String, Object?>>[
          for (final service in services)
            if (_gattService(service) case final entry?) entry,
        ];
      });

  /// Liest ein Merkmal.
  ///
  /// Wirft [FormatException] bei einer ungültigen UUID.
  Future<Uint8List> read(String id, String service, String characteristic) =>
      _onDevice(id, (key) async {
        final target = _target(service, characteristic);
        await _connections.demand(key);
        final result = await _helper.call(HelperOp.read, <String, Object?>{
          'device': key,
          ...target.args,
        });
        final data = result['data'];
        if (data is! String) throw _unreadable(key, HelperOp.read);
        try {
          return base64Decode(data);
        } on FormatException {
          throw _unreadable(key, HelperOp.read);
        }
      });

  /// Schreibt [packets] nacheinander, jedes als eigener Schreibvorgang und
  /// erst nach der Antwort auf das vorige; liefert die Zahl der Pakete.
  ///
  /// Nur mit gültiger Belegung [lease]; jedes Paket erneuert sie. Ist ein
  /// Paket länger, als die Schreibart erlaubt, geht gar nichts hinaus
  /// (`bluetooth_write_too_long`) – ohne Antwort kürzte das System sonst
  /// stumm. Mit [generation] schreibt die Brücke nur in diese Verbindung,
  /// nie in eine neu aufgebaute (dort fehlte der Anfang des Auftrags).
  /// Endet der Vorgang mittendrin (Belegung weg, Verbindung weg, Fehler des
  /// Geräts), trägt der Fehler `detail: {written: n}`.
  ///
  /// Wirft [FormatException] bei einer ungültigen UUID.
  Future<int> write(
    String id,
    String service,
    String characteristic,
    List<Uint8List> packets, {
    required bool withResponse,
    required String lease,
    int? generation,
  }) => _onDevice(id, (key) {
    final target = _target(service, characteristic);
    if (!_leases.renew(key, lease)) {
      throw _failure(errorBluetoothLeaseRequired);
    }
    return _serial(
      key,
      () => _writePackets(
        key,
        target,
        packets,
        withResponse: withResponse,
        lease: lease,
        generation: generation,
      ),
    );
  });

  /// Abonniert ein Merkmal für diesen Bedarf; nach jedem Neuverbinden stellt
  /// Connect das Abo selbst wieder her.
  ///
  /// Wirft [FormatException] bei einer ungültigen UUID.
  Future<void> subscribe(String id, String service, String characteristic) =>
      _onDevice(id, (key) {
        final target = _target(service, characteristic);
        return _connections.subscribe(
          key,
          target.service,
          target.characteristic,
        );
      });

  /// Beendet ein Abo.
  ///
  /// Wirft [FormatException] bei einer ungültigen UUID.
  Future<void> unsubscribe(String id, String service, String characteristic) =>
      _onDevice(id, (key) {
        final target = _target(service, characteristic);
        return _connections.unsubscribe(
          key,
          target.service,
          target.characteristic,
        );
      });

  /// Ob [id] zugelassen ist; ein Gerät, das gerade vergessen wird, ist es
  /// schon nicht mehr. Berührt Bluetooth nicht.
  ///
  /// Für Zugriffe, die die Brücke selbst nicht prüft ([notifications],
  /// [generationOf], [renewLease]): die Route fragt vorher. [releaseLease]
  /// bleibt bewusst ohne diese Frage – eine Freigabe nach dem Vergessen ist
  /// kein Fehler.
  Future<bool> isApproved(String id) async {
    final key = id.toLowerCase();
    if (_forgetting.contains(key)) return false;
    final config = await _store.load();
    return !_forgetting.contains(key) &&
        config.bluetoothDevices.any((d) => d.id == key);
  }

  /// Gepufferte Meldungen der laufenden Verbindung. Nicht zugelassene Geräte
  /// haben keine: verbunden wird nur nach der Zulassung, und Vergessen
  /// verwirft den Puffer.
  List<NotificationEntry> notifications(String id) =>
      _connections.notifications(id);

  /// Nummer der laufenden bzw. letzten Verbindung; 0 vor der ersten.
  int generationOf(String id) => _connections.generationOf(id);

  /// Belegt das Gerät; wartet höchstens [wait] (bis 30 s), sonst
  /// `bluetooth_busy`.
  Future<Lease> acquireLease(String id, {Duration wait = _leaseWaitMax}) =>
      _onDevice(id, (key) {
        final bounded = wait.isNegative
            ? Duration.zero
            : (wait > _leaseWaitMax ? _leaseWaitMax : wait);
        return _leases.acquire(key, wait: bounded);
      });

  /// Verlängert die Belegung; `false`, wenn sie nicht (mehr) gilt.
  bool renewLease(String id, String lease) => _leases.renew(id, lease);

  /// Gibt die Belegung frei; `false`, wenn sie nicht (mehr) gilt.
  bool releaseLease(String id, String lease) => _leases.release(id, lease);

  /// Hört auf: Wartende scheitern, das Hilfsprogramm endet.
  Future<void> close() async {
    _leases.close();
    await _connections.close();
    await _helper.stop();
  }

  // ---------------------------------------------------------------------------
  // Belegung und Verbindung

  /// Ende einer Belegung (normal oder abnorm).
  ///
  /// Das Halten endet erst eine Mikroaufgabe später: bei einer Übergabe hält
  /// so zuerst der Nächste, und die Zahl fällt nie kurz auf null – sonst
  /// bräche ein laufendes stilles Neuverbinden ab, und der Nächste fände das
  /// Gerät getrennt.
  void _leaseEnded(String deviceId) =>
      scheduleMicrotask(() => _connections.unhold(deviceId));

  /// Eine Belegung ist ohne Freigabe zu Ende (Tab weg, Ablauf): wie beim
  /// Neuladen mit Web Bluetooth fällt die Verbindung, und das Gerät verwirft
  /// einen halben Auftrag.
  Future<void> _leaseAbandoned(String deviceId) {
    _log.info(
      'Bluetooth: Belegung von $deviceId ohne Freigabe beendet; '
      'Verbindung wird zurückgesetzt.',
    );
    return _connections.reset(deviceId);
  }

  // ---------------------------------------------------------------------------
  // Schreiben

  Future<T> _serial<T>(String key, Future<T> Function() job) {
    final previous = _writing[key] ?? Future<void>.value();
    final result = previous.then((_) => job());
    final done = result.then<void>((_) {}, onError: (Object _) {});
    _writing[key] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_writing[key], done)) _writing.remove(key);
      }),
    );
    return result;
  }

  Future<int> _writePackets(
    String key,
    _Target target,
    List<Uint8List> packets, {
    required bool withResponse,
    required String lease,
    int? generation,
  }) async {
    if (!_leases.renew(key, lease)) {
      throw _failure(errorBluetoothLeaseRequired);
    }
    if (packets.isEmpty) return 0;
    final current = await _connections.demand(key);
    if (generation != null && generation != current) {
      throw _failure(
        errorBluetoothDisconnected,
        detail: <String, Object?>{'written': 0},
      );
    }

    final max = _connections.maxWriteLength(key) ?? _fallbackMaxWrite;
    final limit = withResponse ? max.withResponse : max.withoutResponse;
    for (var i = 0; i < packets.length; i++) {
      if (packets[i].length > limit) {
        throw _failure(
          errorBluetoothWriteTooLong,
          detail: <String, Object?>{
            'written': 0,
            'packet': i,
            'length': packets[i].length,
            'max': limit,
          },
        );
      }
    }

    final started = _clock();
    final art = withResponse ? 'mit' : 'ohne';
    var written = 0;
    var bytes = 0;
    try {
      for (final packet in packets) {
        // Läuft die Belegung ab oder wird sie entzogen, schreibt ab hier
        // vielleicht schon ein anderer; fällt die Verbindung, beginnt eine
        // neue ohne den Anfang des Auftrags.
        if (!_leases.renew(key, lease)) {
          throw _failure(errorBluetoothLeaseRequired);
        }
        if (!_connections.isConnected(key) ||
            _connections.generationOf(key) != current) {
          throw _failure(errorBluetoothDisconnected);
        }
        await _helper.call(HelperOp.write, <String, Object?>{
          'device': key,
          ...target.args,
          'data': base64Encode(packet),
          'withResponse': withResponse,
        });
        written++;
        bytes += packet.length;
      }
    } on BluetoothFailure catch (failure) {
      final mapped = _translate(failure);
      _log.warn(
        'Bluetooth: $key ${target.characteristic}: Schreiben nach $written '
        'von ${packets.length} Paket(en) abgebrochen (${mapped.code}).',
      );
      throw BluetoothFailure(
        mapped.code,
        mapped.message,
        detail: <String, Object?>{'written': written},
      );
    }
    final ms = _clock().difference(started).inMilliseconds;
    // Nie die Bytes selbst: ein Etikett trägt einen Gutscheincode.
    _log.info(
      'Bluetooth: $key ${target.characteristic}: $written Paket(e), '
      '$bytes Byte $art Antwort in $ms ms geschrieben.',
    );
    return written;
  }

  // ---------------------------------------------------------------------------
  // Suche

  Future<List<Map<String, Object?>>> _runScan(Duration duration) async {
    final found = <String, _Found>{};
    final subscription = _helper.events.listen((event) {
      if (event.event != HelperEventName.discovered) return;
      final device = event.data['device'];
      if (device is! String || !isValidDeviceId(device)) return;
      final entry = found.putIfAbsent(device.toLowerCase(), _Found.new);
      final name = event.data['name'];
      if (name is String && name.isNotEmpty) entry.name = name;
      final rssi = event.data['rssi'];
      if (rssi is int) entry.rssi = rssi;
      final services = event.data['services'];
      if (services is List) {
        for (final uuid in services.whereType<String>()) {
          if (_uuidOrNull(uuid) case final long?) entry.services.add(long);
        }
      }
    });
    try {
      await _helper.call(HelperOp.scan, <String, Object?>{
        'ms': duration.inMilliseconds,
      });
    } on BluetoothFailure catch (failure) {
      throw _translate(failure);
    } finally {
      // Ein Broadcast-Abo endet sofort; auf das Ergebnis wartet niemand.
      unawaited(subscription.cancel());
    }

    _scanNames = <String, String>{
      for (final e in found.entries)
        if (e.value.name case final name?) e.key: name,
    };
    final approved = <String>{
      for (final device in (await _store.load()).bluetoothDevices) device.id,
    };
    _log.info(
      'Bluetooth: Suche (${duration.inSeconds} s) fand ${found.length} '
      'Gerät(e).',
    );
    return <Map<String, Object?>>[
      for (final e in found.entries)
        <String, Object?>{
          'id': e.key,
          'name': e.value.name,
          'rssi': e.value.rssi,
          'services': e.value.services.toList(),
          'approved': approved.contains(e.key),
        },
    ];
  }

  // ---------------------------------------------------------------------------
  // Hilfen

  void _requireAvailable() {
    if (!available) throw _failure(errorBluetoothUnsupported);
  }

  /// Führt [action] für ein zugelassenes Gerät aus und übersetzt jeden
  /// Fehler in einen Code der Brücke.
  Future<T> _onDevice<T>(
    String id,
    FutureOr<T> Function(String key) action,
  ) async {
    _requireAvailable();
    final key = id.toLowerCase();
    if (!await isApproved(key)) throw _failure(errorBluetoothDeviceUnknown);
    try {
      return await action(key);
    } on BluetoothFailure catch (failure) {
      throw _translate(failure);
    }
  }

  /// Dienst und Merkmal in langer Form; gesperrt → `bluetooth_blocked`.
  _Target _target(String service, String characteristic) {
    final target = _Target(
      canonicalUuid(service),
      canonicalUuid(characteristic),
    );
    if (isBlockedService(target.service) ||
        isBlockedCharacteristic(target.characteristic)) {
      throw _failure(errorBluetoothBlocked);
    }
    return target;
  }

  /// Ein Fehler von Hilfsprogramm, Verbindungen oder Belegung als Fehler der
  /// Brücke; was sie nicht kennt, wird `bluetooth_unavailable`.
  BluetoothFailure _translate(BluetoothFailure failure) {
    final code = bluetoothErrorMessages.containsKey(failure.code)
        ? failure.code
        : _helperCodes[failure.code];
    if (code == null) {
      _log.warn(
        'Bluetooth: unerwarteter Fehler ${failure.code} '
        '(${failure.message}).',
      );
      return _failure(errorBluetoothUnavailable, detail: failure.detail);
    }
    return _failure(code, detail: failure.detail);
  }

  BluetoothFailure _unreadable(String key, String op) {
    // Nie den Inhalt: er könnte Nutzdaten tragen.
    _log.warn('Bluetooth: unlesbare Antwort auf $op von $key verworfen.');
    return _failure(errorBluetoothUnavailable);
  }

  /// Ein Dienst aus der Antwort auf `gatt`, ohne Gesperrtes; `null`, wenn er
  /// gesperrt oder unbrauchbar ist.
  Map<String, Object?>? _gattService(Object? raw) {
    final service = readMap(raw);
    final uuid = _uuidOrNull(service?['uuid']);
    if (service == null || uuid == null || isBlockedService(uuid)) return null;
    final characteristics = service['characteristics'];
    return <String, Object?>{
      'uuid': uuid,
      'characteristics': <Map<String, Object?>>[
        if (characteristics is List)
          for (final entry in characteristics)
            if (readMap(entry) case final c?)
              if (_uuidOrNull(c['uuid']) case final id?)
                if (!isBlockedCharacteristic(id))
                  <String, Object?>{
                    'uuid': id,
                    'properties': readStringList(c['properties']),
                  },
      ],
    };
  }

  static String? _uuidOrNull(Object? value) {
    if (value is! String) return null;
    try {
      return canonicalUuid(value);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> _deviceJson(BluetoothDeviceConfig device) =>
      <String, Object?>{
        'id': device.id,
        'name': device.name,
        'approvedAt': device.approvedAt.toUtc().toIso8601String(),
        'connected': _connections.isConnected(device.id),
        'generation': _connections.generationOf(device.id),
      };
}

/// Dienst und Merkmal, lang und klein.
class _Target {
  _Target(this.service, this.characteristic);

  final String service;
  final String characteristic;

  Map<String, Object?> get args => <String, Object?>{
    'service': service,
    'characteristic': characteristic,
  };
}

/// Ein Gerät aus der laufenden Suche.
class _Found {
  String? name;
  int? rssi;
  final Set<String> services = <String>{};
}
