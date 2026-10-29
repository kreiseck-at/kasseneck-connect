import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:kasseneck_connect/src/bluetooth/helper.dart';
import 'package:kasseneck_connect/src/bluetooth/leases.dart';
import 'package:test/test.dart';

/// Erfundene Gerätekennungen.
const String _drucker = '3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b';
const String _waage = '9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4';

final DateTime _start = DateTime.utc(2026, 10, 29, 9);

String _name(String id) => switch (id) {
  _drucker => 'drucker',
  _waage => 'waage',
  _ => id,
};

/// Ausgang eines Aufrufs, ohne `await` – in `fakeAsync` läuft die Zeit nur
/// auf Zuruf.
class _Ausgang<T> {
  T? wert;
  Object? fehler;
  bool fertig = false;

  String? get code => switch (fehler) {
    BluetoothFailure(:final code) => code,
    _ => null,
  };
}

_Ausgang<T> _verfolge<T>(Future<T> aufruf) {
  final ausgang = _Ausgang<T>();
  unawaited(
    aufruf.then<void>(
      (wert) {
        ausgang
          ..wert = wert
          ..fertig = true;
      },
      onError: (Object fehler) {
        ausgang
          ..fehler = fehler
          ..fertig = true;
      },
    ),
  );
  return ausgang;
}

/// Belegungen in `fakeAsync`, jeder Rückruf mitgeschrieben.
class _Aufbau {
  _Aufbau(
    this.async, {
    FutureOr<void> Function(String deviceId)? abnorm,
    Random? random,
  }) {
    leases = DeviceLeases(
      onAbnormalEnd: (id) {
        rueckrufe.add('abnorm ${_name(id)}');
        return abnorm?.call(id);
      },
      onAcquired: (id) => rueckrufe.add('beginn ${_name(id)}'),
      onEnded: (id) => rueckrufe.add('ende ${_name(id)}'),
      clock: () => _start.add(async.elapsed + sprung),
      random: random,
    );
  }

  final FakeAsync async;
  late final DeviceLeases leases;
  final List<String> rueckrufe = <String>[];

  /// So weit ist die Uhr den Zeitgebern voraus (Ruhezustand: die Uhr läuft
  /// weiter, Zeitgeber können stehen).
  Duration sprung = Duration.zero;

  /// Holt eine Belegung und gibt sie zurück; das Gerät muss frei sein.
  Lease hole(String deviceId) {
    final ausgang = _verfolge(leases.acquire(deviceId));
    async.flushMicrotasks();
    expect(ausgang.fertig, isTrue, reason: '$deviceId ist nicht frei');
    return ausgang.wert!;
  }

  int zaehle(String eintrag) => rueckrufe.where((r) => r == eintrag).length;
}

void main() {
  test('freies Gerät: Belegung ohne Wartezeit, Geräte unabhängig', () {
    fakeAsync((async) {
      final a = _Aufbau(async);

      final drucker = _verfolge(a.leases.acquire(_drucker));
      // Der Beginn ist gemeldet, bevor die Kasse die Belegung in der Hand
      // hat – die Brücke hält die Verbindung schon.
      expect(a.rueckrufe, ['beginn drucker']);
      async.flushMicrotasks();
      expect(async.elapsed, Duration.zero);
      expect(drucker.fertig, isTrue);
      expect(drucker.wert!.deviceId, _drucker);
      expect(drucker.wert!.expiresAt, _start.add(const Duration(seconds: 5)));
      expect(a.leases.holds(_drucker, drucker.wert!.id), isTrue);

      final waage = a.hole(_waage);
      expect(a.leases.holds(_waage, waage.id), isTrue);
      expect(a.rueckrufe, ['beginn drucker', 'beginn waage']);
    });
  });

  test('zweite Belegung wartet, bis die erste freigegeben ist', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final erste = a.hole(_drucker);

      final zweite = _verfolge(a.leases.acquire(_drucker));
      for (var i = 0; i < 5; i++) {
        async.elapse(const Duration(seconds: 3));
        expect(a.leases.renew(_drucker, erste.id), isTrue);
      }
      expect(zweite.fertig, isFalse);
      expect(a.rueckrufe, ['beginn drucker']);

      expect(a.leases.release(_drucker, erste.id), isTrue);
      async.flushMicrotasks();
      expect(zweite.fertig, isTrue);
      expect(zweite.fehler, isNull);
      expect(zweite.wert!.id, isNot(erste.id));
      expect(a.leases.holds(_drucker, zweite.wert!.id), isTrue);
      expect(a.leases.holds(_drucker, erste.id), isFalse);
      expect(a.rueckrufe, ['beginn drucker', 'ende drucker', 'beginn drucker']);
      expect(a.zaehle('abnorm drucker'), 0);
    });
  });

  test('Warteschlange in Reihenfolge', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      var halter = a.hole(_drucker);

      final wartende = <_Ausgang<Lease>>[];
      for (var i = 0; i < 3; i++) {
        wartende.add(_verfolge(a.leases.acquire(_drucker)));
        async.elapse(const Duration(seconds: 1));
        expect(a.leases.renew(_drucker, halter.id), isTrue);
      }

      for (var i = 0; i < 3; i++) {
        expect(a.leases.release(_drucker, halter.id), isTrue);
        async.flushMicrotasks();
        expect(
          [for (final w in wartende) w.fertig],
          [for (var j = 0; j < 3; j++) j <= i],
          reason: 'nach der ${i + 1}. Freigabe',
        );
        halter = wartende[i].wert!;
      }
      expect(a.zaehle('beginn drucker'), 4);
      expect(a.zaehle('ende drucker'), 3);
    });
  });

  test('ohne Erneuerung endet die Belegung nach 5 s abnorm, onAbnormalEnd '
      'genau einmal', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final lease = a.hole(_drucker);

      async.elapse(const Duration(milliseconds: 4999));
      expect(a.leases.holds(_drucker, lease.id), isTrue);
      expect(a.rueckrufe, ['beginn drucker']);

      async.elapse(const Duration(milliseconds: 1));
      expect(a.rueckrufe, ['beginn drucker', 'abnorm drucker', 'ende drucker']);
      expect(a.leases.holds(_drucker, lease.id), isFalse);
      expect(a.leases.renew(_drucker, lease.id), isFalse);
      expect(a.leases.release(_drucker, lease.id), isFalse);

      async.elapse(const Duration(minutes: 1));
      expect(a.zaehle('abnorm drucker'), 1);
      expect(a.zaehle('ende drucker'), 1);

      // Danach ist das Gerät wieder frei.
      a.hole(_drucker);
    });
  });

  test('release ruft onAbnormalEnd nicht', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final lease = a.hole(_drucker);

      async.elapse(const Duration(seconds: 2));
      expect(a.leases.release(_drucker, lease.id), isTrue);
      expect(a.rueckrufe, ['beginn drucker', 'ende drucker']);

      async.elapse(const Duration(minutes: 1));
      expect(a.leases.release(_drucker, lease.id), isFalse);
      expect(a.rueckrufe, ['beginn drucker', 'ende drucker']);
    });
  });

  test('renew verlängert, fremde lease-ID verlängert nicht', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final lease = a.hole(_drucker);
      final waage = a.hole(_waage);

      async.elapse(const Duration(seconds: 4));
      expect(a.leases.renew(_drucker, lease.id), isTrue);
      expect(lease.expiresAt, _start.add(const Duration(seconds: 9)));
      expect(a.leases.renew(_waage, waage.id), isTrue);

      async.elapse(const Duration(seconds: 3));
      expect(a.leases.renew(_drucker, 'AAAAAAAAAAAAAAAAAAAAAA'), isFalse);
      expect(a.leases.renew(_drucker, waage.id), isFalse);
      expect(a.leases.renew(_waage, lease.id), isFalse);
      expect(lease.expiresAt, _start.add(const Duration(seconds: 9)));

      async.elapse(const Duration(milliseconds: 1999));
      expect(a.zaehle('abnorm drucker'), 0);
      async.elapse(const Duration(milliseconds: 1));
      expect(a.zaehle('abnorm drucker'), 1);
      expect(a.leases.renew(_drucker, lease.id), isFalse);
      // Die Waage wurde mit der Drucker-ID nie verlängert.
      expect(a.zaehle('abnorm waage'), 1);
    });
  });

  test('fremdes Gerät oder fremde lease-ID: nichts ändert sich', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final lease = a.hole(_drucker);

      expect(a.leases.release(_waage, lease.id), isFalse);
      expect(a.leases.release(_drucker, 'AAAAAAAAAAAAAAAAAAAAAA'), isFalse);
      expect(a.leases.holds(_waage, lease.id), isFalse);
      expect(a.leases.holds(_drucker, ''), isFalse);
      expect(a.leases.renew('unbekannt', lease.id), isFalse);

      expect(a.leases.holds(_drucker, lease.id), isTrue);
      expect(lease.expiresAt, _start.add(const Duration(seconds: 5)));
      expect(a.rueckrufe, ['beginn drucker']);
    });
  });

  test('nach 30 s Warten bluetooth_busy', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final erste = a.hole(_drucker);

      final zweite = _verfolge(a.leases.acquire(_drucker));
      for (var i = 0; i < 7; i++) {
        async.elapse(const Duration(seconds: 4));
        expect(a.leases.renew(_drucker, erste.id), isTrue);
      }
      async.elapse(const Duration(milliseconds: 1999));
      expect(zweite.fertig, isFalse);

      async.elapse(const Duration(milliseconds: 1));
      expect(zweite.code, 'bluetooth_busy');
      expect(a.leases.holds(_drucker, erste.id), isTrue);

      // Kürzeres Warten auf Wunsch.
      final kurz = _verfolge(
        a.leases.acquire(_drucker, wait: const Duration(seconds: 2)),
      );
      async.elapse(const Duration(seconds: 2));
      expect(kurz.code, 'bluetooth_busy');
      expect(a.rueckrufe, ['beginn drucker']);
    });
  });

  test(
    'wer nicht mehr wartet, bekommt später nichts; der Nächste rückt vor',
    () {
      fakeAsync((async) {
        final a = _Aufbau(async);
        final erste = a.hole(_drucker);

        final ungeduldig = _verfolge(
          a.leases.acquire(_drucker, wait: const Duration(seconds: 2)),
        );
        final geduldig = _verfolge(a.leases.acquire(_drucker));
        async.elapse(const Duration(seconds: 2));
        expect(ungeduldig.code, 'bluetooth_busy');

        expect(a.leases.release(_drucker, erste.id), isTrue);
        async.flushMicrotasks();
        expect(geduldig.wert, isNotNull);
        expect(a.rueckrufe, [
          'beginn drucker',
          'ende drucker',
          'beginn drucker',
        ]);

        expect(a.leases.release(_drucker, geduldig.wert!.id), isTrue);
        async.elapse(const Duration(minutes: 1));
        expect(a.rueckrufe, [
          'beginn drucker',
          'ende drucker',
          'beginn drucker',
          'ende drucker',
        ]);
      });
    },
  );

  test('Ablauf während Bluetooth aus: genau ein Rückruf, kein zweiter nach '
      'poweredOn', () {
    fakeAsync((async) {
      // Das Zurücksetzen der Brücke wird erst fertig, wenn Bluetooth wieder
      // an ist.
      final poweredOn = Completer<void>();
      final a = _Aufbau(async, abnorm: (_) => poweredOn.future);
      final erste = a.hole(_drucker);
      final zweite = _verfolge(a.leases.acquire(_drucker));

      // Bluetooth aus: die Kasse erneuert nicht mehr.
      async.elapse(const Duration(seconds: 5));
      expect(a.rueckrufe, ['beginn drucker', 'abnorm drucker']);
      expect(a.leases.renew(_drucker, erste.id), isFalse);
      expect(a.leases.release(_drucker, erste.id), isFalse);
      expect(a.leases.holds(_drucker, erste.id), isFalse);

      // Der Nächste wartet, bis das Zurücksetzen fertig ist.
      async.elapse(const Duration(seconds: 10));
      expect(zweite.fertig, isFalse);
      expect(a.rueckrufe, ['beginn drucker', 'abnorm drucker']);

      poweredOn.complete();
      async.flushMicrotasks();
      expect(a.rueckrufe, [
        'beginn drucker',
        'abnorm drucker',
        'ende drucker',
        'beginn drucker',
      ]);
      expect(zweite.wert, isNotNull);

      expect(a.leases.renew(_drucker, erste.id), isFalse);
      expect(a.leases.release(_drucker, zweite.wert!.id), isTrue);
      async.elapse(const Duration(minutes: 1));
      expect(a.zaehle('abnorm drucker'), 1);
      expect(a.zaehle('ende drucker'), 2);
    });
  });

  test('Ruhezustand: die Uhr läuft weiter, Zeitgeber stehen – genau ein '
      'abnormes Ende', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final lease = a.hole(_drucker);
      async.elapse(const Duration(seconds: 2));

      a.sprung = const Duration(minutes: 10);
      expect(a.leases.renew(_drucker, lease.id), isFalse);
      async.flushMicrotasks();
      expect(a.rueckrufe, ['beginn drucker', 'abnorm drucker', 'ende drucker']);

      // Der Zeitgeber der alten Belegung meldet kein zweites Ende.
      async.elapse(const Duration(minutes: 1));
      expect(a.zaehle('abnorm drucker'), 1);
      expect(a.zaehle('ende drucker'), 1);
      a.hole(_drucker);
    });
  });

  test('Fehler in Rückrufen halten die Übergabe nicht auf', () {
    fakeAsync((async) {
      final rueckrufe = <String>[];
      var abnorm = 0;
      final leases = DeviceLeases(
        onAbnormalEnd: (id) {
          abnorm++;
          rueckrufe.add('abnorm');
          if (abnorm == 1) throw StateError('Zurücksetzen gescheitert');
          return Future<void>.error(StateError('Zurücksetzen gescheitert'));
        },
        onAcquired: (_) => rueckrufe.add('beginn'),
        onEnded: (_) {
          rueckrufe.add('ende');
          throw StateError('Freigabe gescheitert');
        },
        clock: () => _start.add(async.elapsed),
      );

      unawaited(leases.acquire(_drucker));
      final zweite = _verfolge(leases.acquire(_drucker));
      final dritte = _verfolge(leases.acquire(_drucker));
      async.elapse(const Duration(seconds: 5));
      expect(zweite.wert, isNotNull);
      expect(dritte.fertig, isFalse);

      async.elapse(const Duration(seconds: 5));
      expect(dritte.wert, isNotNull);
      expect(leases.release(_drucker, dritte.wert!.id), isTrue);
      async.flushMicrotasks();
      expect(rueckrufe, [
        'beginn',
        'abnorm',
        'ende',
        'beginn',
        'abnorm',
        'ende',
        'beginn',
        'ende',
      ]);
    });
  });

  test('Lease-IDs: 16 Zufallsbytes, base64url ohne Polster', () {
    fakeAsync((async) {
      final a = _Aufbau(async, random: Random(7));
      final eins = a.hole(_drucker);
      final zwei = a.hole(_waage);

      for (final id in [eins.id, zwei.id]) {
        expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
        expect(base64Url.decode('$id=='), hasLength(16));
      }
      expect(eins.id, isNot(zwei.id));

      // Der übergebene Zufall wird benutzt.
      final b = _Aufbau(async, random: Random(7));
      expect(b.hole(_drucker).id, eins.id);
    });
  });

  test('close: Wartende scheitern mit bluetooth_unavailable, laufende '
      'Belegungen enden ohne Zurücksetzen', () {
    fakeAsync((async) {
      final zurueckgesetzt = Completer<void>();
      final a = _Aufbau(async, abnorm: (_) => zurueckgesetzt.future);

      // Die Waage läuft ab und wird gerade zurückgesetzt.
      a.hole(_waage);
      final wartetAufWaage = _verfolge(a.leases.acquire(_waage));
      async.elapse(const Duration(seconds: 5));
      expect(a.rueckrufe, ['beginn waage', 'abnorm waage']);

      final drucker = a.hole(_drucker);
      final wartetAufDrucker = _verfolge(a.leases.acquire(_drucker));

      a.leases.close();
      async.flushMicrotasks();
      expect(wartetAufWaage.code, 'bluetooth_unavailable');
      expect(wartetAufDrucker.code, 'bluetooth_unavailable');
      expect(a.rueckrufe, [
        'beginn waage',
        'abnorm waage',
        'beginn drucker',
        'ende drucker',
      ]);

      // Das laufende Zurücksetzen endet noch mit seinem onEnded, vergibt
      // aber nichts mehr.
      zurueckgesetzt.complete();
      async.elapse(const Duration(minutes: 1));
      expect(a.rueckrufe, [
        'beginn waage',
        'abnorm waage',
        'beginn drucker',
        'ende drucker',
        'ende waage',
      ]);

      expect(a.leases.holds(_drucker, drucker.id), isFalse);
      expect(a.leases.renew(_drucker, drucker.id), isFalse);
      expect(a.leases.release(_drucker, drucker.id), isFalse);
      final danach = _verfolge(a.leases.acquire(_drucker));
      async.flushMicrotasks();
      expect(danach.code, 'bluetooth_unavailable');

      a.leases.close();
      expect(a.rueckrufe, hasLength(5));
    });
  });

  test('revoke beendet die Belegung normal, Wartende scheitern mit '
      'bluetooth_device_unknown', () {
    fakeAsync((async) {
      final a = _Aufbau(async);
      final erste = a.hole(_drucker);
      final zweite = _verfolge(a.leases.acquire(_drucker));
      final dritte = _verfolge(a.leases.acquire(_drucker.toUpperCase()));
      final waage = a.hole(_waage);

      expect(a.leases.revoke(_drucker.toUpperCase()), isTrue);
      async.flushMicrotasks();
      expect(zweite.code, 'bluetooth_device_unknown');
      expect(dritte.code, 'bluetooth_device_unknown');
      expect(a.rueckrufe, ['beginn drucker', 'beginn waage', 'ende drucker']);
      expect(a.leases.holds(_drucker, erste.id), isFalse);
      expect(a.leases.renew(_drucker, erste.id), isFalse);
      expect(a.leases.release(_drucker, erste.id), isFalse);

      // Der alte Zeitgeber meldet kein Ende mehr, die Waage bleibt belegt.
      expect(a.leases.renew(_waage, waage.id), isTrue);
      async.elapse(const Duration(seconds: 4));
      expect(a.leases.renew(_waage, waage.id), isTrue);
      async.elapse(const Duration(seconds: 4));
      expect(a.zaehle('abnorm drucker'), 0);
      expect(a.zaehle('ende drucker'), 1);
      expect(a.zaehle('abnorm waage'), 0);

      // Danach ist das Gerät frei wie neu.
      final neu = a.hole(_drucker);
      expect(neu.id, isNot(erste.id));
      expect(a.zaehle('beginn drucker'), 2);

      // Nichts zu beenden: false, kein Rückruf.
      expect(a.leases.release(_drucker, neu.id), isTrue);
      final vorher = List<String>.of(a.rueckrufe);
      expect(a.leases.revoke(_drucker), isFalse);
      expect(a.rueckrufe, vorher);
    });
  });

  test('revoke während des Zurücksetzens: ein Ende, niemand rückt nach', () {
    fakeAsync((async) {
      final zurueckgesetzt = Completer<void>();
      final a = _Aufbau(async, abnorm: (_) => zurueckgesetzt.future);
      a.hole(_drucker);
      async.elapse(const Duration(seconds: 5));
      expect(a.rueckrufe, ['beginn drucker', 'abnorm drucker']);
      final wartet = _verfolge(a.leases.acquire(_drucker));

      expect(a.leases.revoke(_drucker), isTrue);
      async.flushMicrotasks();
      expect(wartet.code, 'bluetooth_device_unknown');

      zurueckgesetzt.complete();
      async.elapse(const Duration(minutes: 1));
      expect(a.rueckrufe, ['beginn drucker', 'abnorm drucker', 'ende drucker']);

      // Nach dem Zurücksetzen ist das Gerät wieder frei.
      a.hole(_drucker);
      expect(a.zaehle('beginn drucker'), 2);

      // Nach close beendet revoke nichts mehr (close hat das schon getan).
      a.leases.close();
      expect(a.leases.revoke(_drucker), isFalse);
      expect(a.zaehle('ende drucker'), 2);
    });
  });
}
