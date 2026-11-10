@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/fake_hps.dart';
import 'support/fake_printer.dart';
import 'support/fake_process_runner.dart';
import 'support/virtuelles_netz.dart';

const Map<int, int> _gesund = <int, int>{2: 0x12, 4: 0x12};
const String _tid = '12345678';

/// Ein Bon mit erkennbarem Inhalt: Absender und laufende Nummer.
Uint8List _bon(String inhalt) =>
    Uint8List.fromList(<int>[0x1B, 0x40, ...utf8.encode(inhalt), 0x0A]);

String _inhalt(List<int> bytes) =>
    utf8.decode(bytes.sublist(2, bytes.length - 1));

/// Ein Agent wie im Betrieb, aber im virtuellen Netz, mit Fake-Prozessen
/// (arp, caffeinate) und gezähltem Neustart.
class _Aufbau {
  _Aufbau._(this.temp, this.store, this.netz, this.prozesse);

  static Future<_Aufbau> starten({
    String betriebssystem = 'macos',
    PrinterRegistry Function(ConfigStore store, EventBus bus)? registry,
  }) async {
    final temp = Directory.systemTemp.createTempSync('connect-gleich-');
    final store = ConfigStore.forDirectory(temp);
    final netz = VirtuellesNetz();
    final prozesse = FakeProcessRunner()
      ..antwort = (programm, argumente) {
        switch (programm) {
          case 'arp':
            final ausgabe = argumente.first == '-an'
                ? netz.arpTabelle()
                : netz.arpEinzeln(argumente.last);
            return Future<ProcessResult?>.value(
              ProcessResult(1, 0, ausgabe, ''),
            );
          case 'caffeinate':
            // Läuft, bis es beendet wird.
            return Completer<ProcessResult?>().future;
        }
        return Future<ProcessResult?>.value();
      };
    final a = _Aufbau._(temp, store, netz, prozesse);
    final bus = EventBus();
    a.agent = Agent(
      store: store,
      log: AgentLog(Directory(p.join(temp.path, 'logs'))),
      preferredPort: 0,
      openBrowser: false,
      environment: const <String, String>{},
      events: bus,
      registry: registry?.call(store, bus),
      runProcess: prozesse.runner,
      startProcess: prozesse.starter,
      betriebssystem: betriebssystem,
      schnittstellen: () async => const <LocalInterface>[VirtuellesNetz.eigene],
      geraeteVerbindung: netz.verbinden,
      geraeteProbe: netz.tcp,
      discovery: PrinterDiscovery(
        mdns: (_) async => const <DiscoveredPrinter>[],
        interfaces: () async => const <LocalInterface>[VirtuellesNetz.eigene],
        tcp: netz.tcp,
      ),
      neustart: () async => a.neustarts++,
    );
    a._bus = bus;
    await a.agent.start();
    for (var i = 0; i < 3; i++) {
      a.kassen.add(await a.agent.context.pairing.issueToken());
    }
    return a;
  }

  final Directory temp;
  final ConfigStore store;
  final VirtuellesNetz netz;
  final FakeProcessRunner prozesse;
  late final Agent agent;
  late final EventBus _bus;

  /// Drei gekoppelte Kassen (Tabs, Browser).
  final List<String> kassen = <String>[];
  int neustarts = 0;

  Future<String> drucker(
    String host,
    FakeTcpPrinter fake, {
    String? serial,
    String? mac,
  }) async {
    netz.stelle(host, 9100, fake.port, mac: mac);
    final saved = await agent.printers.upsert(
      PrinterConfig(
        id: '',
        name: host,
        kind: PrinterKind.tcp9100,
        host: host,
        serial: serial,
        mac: mac,
      ),
    );
    return saved.id;
  }

  Future<AgentAntwort> drucke(String kasse, String id, String inhalt) =>
      anAgent(
        agent.port,
        'POST',
        '/v1/print',
        token: kasse,
        rumpf: <String, Object?>{
          'printerId': id,
          'jobId': inhalt,
          'bytes': base64Encode(_bon(inhalt)),
        },
      );

  Future<AgentAntwort> zahle(String kasse, int hpsPort, int nummer) => anAgent(
    agent.port,
    'POST',
    '/v1/terminal/payment',
    token: kasse,
    rumpf: <String, Object?>{
      'host': '127.0.0.1',
      'port': hpsPort,
      'tid': _tid,
      'amountCents': 100,
      'transactionId': '$nummer',
    },
  );

  int get caffeinateGestartet =>
      prozesse.calls.where((c) => c.executable == 'caffeinate').length;

  int get caffeinateBeendet =>
      prozesse.killed.where((c) => c.executable == 'caffeinate').length;

  Future<void> aufraeumen() async {
    await agent.stop();
    await _bus.close();
    temp.deleteSync(recursive: true);
  }
}

/// Ein Druckertreiber, der erst druckt, wenn [weiter] erfüllt ist.
class _LangsamerTreiber implements PrinterDriver {
  _LangsamerTreiber(this.weiter);

  final Completer<void> weiter;

  @override
  Future<void> print(
    Uint8List bytes, {
    Duration timeout = defaultPrintTimeout,
  }) => weiter.future;

  @override
  Future<PrinterState> status({Duration timeout = defaultPrintTimeout}) async =>
      PrinterState.online;

  @override
  Future<void> abort() async {}
}

/// Prüft, dass jede Druckverbindung genau einen Bon trägt und jeder Bon genau
/// einmal ankam; liefert die Inhalte in Ankunftsreihenfolge.
List<String> _jederBonGenauEinmal(
  List<FakeTcpPrinter> drucker,
  Set<String> erwartet,
) {
  final angekommen = <String>[];
  for (final fake in drucker) {
    for (final bytes in fake.druckVerbindungen) {
      expect(bytes.first, 0x1B, reason: 'Bon beginnt mit ESC @');
      expect(bytes.where((b) => b == 0x0A), hasLength(1), reason: 'ein Bon');
      angekommen.add(_inhalt(bytes));
    }
    expect(fake.hoechstGleichzeitig, 1, reason: 'nie zwei Verbindungen');
  }
  expect(angekommen.toSet(), erwartet);
  expect(angekommen, hasLength(erwartet.length), reason: 'keiner doppelt');
  return angekommen;
}

void main() {
  test(
    'Drucke aus drei Kassen an einen Drucker, dazu Statusabfragen: '
    'seriell, jeder genau einmal, unverschränkt, Reihenfolge je Kasse',
    () async {
      final a = await _Aufbau.starten();
      addTearDown(a.aufraeumen);
      final fake = await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: 'X5ZT000123'},
      );
      addTearDown(fake.stop);
      final id = await a.drucker('192.168.0.50', fake, serial: 'X5ZT000123');

      final erwartet = <String>{};
      final arbeit = <Future<void>>[
        for (var k = 0; k < 3; k++)
          () async {
            for (var n = 0; n < 15; n++) {
              final inhalt = 'K$k-${n.toString().padLeft(2, '0')}';
              erwartet.add(inhalt);
              final antwort = await a.drucke(a.kassen[k], id, inhalt);
              expect(antwort.ok, isTrue, reason: antwort.text);
            }
          }(),
        () async {
          for (var n = 0; n < 10; n++) {
            final antwort = await anAgent(
              a.agent.port,
              'POST',
              '/v1/printers/$id/status',
              token: a.kassen[n % 3],
            );
            expect(antwort.ok, isTrue);
          }
        }(),
      ];
      await Future.wait(arbeit).timeout(const Duration(seconds: 60));
      await fake.warteAufDruck(erwartet.length - 1);

      final angekommen = _jederBonGenauEinmal(<FakeTcpPrinter>[fake], erwartet);
      for (var k = 0; k < 3; k++) {
        final eigene = angekommen.where((i) => i.startsWith('K$k-')).toList();
        expect(eigene, List<String>.of(eigene)..sort(), reason: 'Kasse $k');
      }
    },
  );

  test('drei Kassen zahlen gleichzeitig: genau eine erreicht das Terminal, '
      'die anderen bekommen sofort terminal_busy', () async {
    final a = await _Aufbau.starten();
    addTearDown(a.aufraeumen);
    final hps = await FakeHpsServer.starten();
    addTearDown(hps.stop);
    hps.verzoegerung['/api/transaction/payment'] = const Duration(
      milliseconds: 300,
    );
    final antworten = await Future.wait(<Future<AgentAntwort>>[
      for (var k = 0; k < 3; k++) a.zahle(a.kassen[k], hps.port, k + 1),
    ]);
    final ok = antworten.where((r) => r.ok).toList();
    final besetzt = antworten
        .where((r) => r.code == errorTerminalBusy)
        .toList();
    expect(ok, hasLength(1));
    expect(besetzt, hasLength(2));
    for (final r in besetzt) {
      expect(r.detail, <String, Object?>{'terminalHttpStatus': 409});
    }
    expect(hps.an('/api/transaction/payment'), hasLength(1));
    expect(hps.hoechstGleichzeitig, 1);
  });

  test('Kasse A druckt (langsam), Kasse B will neu starten und Kasse C zahlt: '
      'restart_busy, ein caffeinate für beide Vorgänge', () async {
    final weiter = Completer<void>();
    final a = await _Aufbau.starten(
      registry: (store, bus) => PrinterRegistry(
        store: store,
        events: bus,
        driverFactory: (_) => _LangsamerTreiber(weiter),
      ),
    );
    addTearDown(a.aufraeumen);
    final hps = await FakeHpsServer.starten();
    addTearDown(hps.stop);
    hps.verzoegerung['/api/transaction/payment'] = const Duration(
      milliseconds: 300,
    );
    await a.store.mutate(
      (c) => c.copyWith(disabledFeatures: <String>['printer_status']),
    );
    final saved = await a.agent.printers.upsert(
      PrinterConfig(
        id: '',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
      ),
    );

    final druck = a.drucke(a.kassen[0], saved.id, 'langsam');
    await warteBis(() async => a.agent.context.vorgaenge!.laufen);
    final zahlung = a.zahle(a.kassen[2], hps.port, 7);
    await warteBis(
      () async => hps.an('/api/transaction/payment').isNotEmpty,
      grund: 'Zahlung am Terminal',
    );

    final neu = await anAgent(
      a.agent.port,
      'POST',
      '/v1/restart',
      token: a.kassen[1],
    );
    expect(neu.code, errorRestartBusy);
    expect(a.agent.context.vorgaenge!.anzahl, 2);
    await warteBis(() async => a.caffeinateGestartet == 1);

    expect((await zahlung).ok, isTrue);
    expect(a.caffeinateBeendet, 0, reason: 'der Druck läuft noch');
    weiter.complete();
    expect((await druck).ok, isTrue);
    await warteBis(() async => a.caffeinateBeendet == 1);
    expect(a.caffeinateGestartet, 1);
    expect(a.neustarts, 0);
  });

  test('umgezogener Drucker, zwei Kassen drucken und eine sucht zugleich: '
      'ein Adresswechsel, jeder Bon genau einmal', () async {
    final a = await _Aufbau.starten();
    addTearDown(a.aufraeumen);
    final fake = await FakeTcpPrinter.start(
      dleEot: _gesund,
      gsI: const <int, String>{68: 'X5ZT000123'},
    );
    addTearDown(fake.stop);
    final id = await a.drucker(
      '192.168.0.50',
      fake,
      serial: 'X5ZT000123',
      mac: '00:26:ab:00:00:01',
    );
    a.netz
      ..entferne('192.168.0.50')
      ..stelle('192.168.0.61', 9100, fake.port, mac: '00:26:ab:00:00:01');

    final ergebnisse = await Future.wait(<Future<AgentAntwort>>[
      a.drucke(a.kassen[0], id, 'A'),
      a.drucke(a.kassen[1], id, 'B'),
      anAgent(
        a.agent.port,
        'POST',
        '/v1/printers/$id/locate',
        token: a.kassen[2],
      ),
    ]).timeout(const Duration(seconds: 30));
    expect(ergebnisse[0].ok, isTrue, reason: ergebnisse[0].text);
    expect(ergebnisse[1].ok, isTrue, reason: ergebnisse[1].text);
    expect(
      ergebnisse[2].ok || ergebnisse[2].code == errorDeviceNotFound,
      isTrue,
      reason: ergebnisse[2].text,
    );
    await fake.warteAufDruck(1);
    _jederBonGenauEinmal(<FakeTcpPrinter>[fake], <String>{'A', 'B'});
    final config = await a.store.load();
    expect(config.printers.single.host, '192.168.0.61');
    expect(config.relocations, hasLength(1));
  });

  test('Last mit festem Startwert: gemischte Aufrufe aus drei Kassen, danach '
      'gelten alle Zusagen', () async {
    final startwert =
        int.tryParse(Platform.environment['CONNECT_LAST_STARTWERT'] ?? '') ??
        20261110;
    printOnFailure('Startwert: $startwert (CONNECT_LAST_STARTWERT)');
    final zufall = Random(startwert);

    final a = await _Aufbau.starten();
    addTearDown(a.aufraeumen);
    final hps = await FakeHpsServer.starten();
    addTearDown(hps.stop);
    hps
      ..verzoegerung['/api/transaction/payment'] = const Duration(
        milliseconds: 40,
      )
      ..verzoegerung['/api/terminals/'] = const Duration(milliseconds: 10);
    final fakes = <FakeTcpPrinter>[
      await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: 'X5ZT000123'},
      ),
      await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: 'X5ZT000124'},
      ),
    ];
    for (final f in fakes) {
      addTearDown(f.stop);
    }
    final ids = <String>[
      await a.drucker(
        '192.168.0.50',
        fakes[0],
        serial: 'X5ZT000123',
        mac: '00:26:ab:00:00:01',
      ),
      await a.drucker(
        '192.168.0.51',
        fakes[1],
        serial: 'X5ZT000124',
        mac: '00:26:ab:00:00:02',
      ),
    ];

    final erwartet = <String>{};
    var zahlungenOk = 0;
    var langsamsterStatus = Duration.zero;
    var nummer = 0;

    Future<void> kasse(int k) async {
      for (var n = 0; n < 100; n++) {
        final token = a.kassen[k];
        final wahl = zufall.nextInt(100);
        if (wahl < 40) {
          final welcher = zufall.nextInt(2);
          final inhalt = 'K$k-$n-D$welcher';
          final antwort = await a.drucke(token, ids[welcher], inhalt);
          expect(antwort.ok, isTrue, reason: antwort.text);
          erwartet.add(inhalt);
        } else if (wahl < 50) {
          final antwort = await anAgent(
            a.agent.port,
            'POST',
            '/v1/printers/${ids[zufall.nextInt(2)]}/status',
            token: token,
          );
          expect(antwort.ok, isTrue);
        } else if (wahl < 65) {
          final uhr = Stopwatch()..start();
          final antwort = await anAgent(
            a.agent.port,
            'GET',
            '/v1/status',
            token: token,
          );
          if (uhr.elapsed > langsamsterStatus) langsamsterStatus = uhr.elapsed;
          expect(antwort.ok, isTrue);
        } else if (wahl < 80) {
          final antwort = await a.zahle(token, hps.port, ++nummer);
          if (antwort.ok) {
            zahlungenOk++;
          } else {
            expect(antwort.code, errorTerminalBusy, reason: antwort.text);
          }
        } else if (wahl < 85) {
          final antwort = await anAgent(
            a.agent.port,
            'POST',
            '/v1/terminal/diagnosis',
            token: token,
            rumpf: <String, Object?>{
              'host': '127.0.0.1',
              'port': hps.port,
              'tid': _tid,
            },
          );
          expect(
            antwort.ok || antwort.code == errorTerminalBusy,
            isTrue,
            reason: antwort.text,
          );
        } else if (wahl < 90) {
          final antwort = await anAgent(
            a.agent.port,
            'POST',
            '/v1/terminal/status',
            token: token,
            rumpf: <String, Object?>{
              'host': '127.0.0.1',
              'port': hps.port,
              'tid': _tid,
              'transactionId': '1',
            },
          );
          expect(antwort.ok, isTrue, reason: antwort.text);
        } else if (wahl < 95) {
          final antwort = await anAgent(
            a.agent.port,
            'POST',
            '/v1/printers/${ids[zufall.nextInt(2)]}/locate',
            token: token,
          );
          expect(
            antwort.code == errorDeviceNotFound ||
                antwort.code == errorTerminalBusy ||
                antwort.ok,
            isTrue,
            reason: antwort.text,
          );
        } else {
          final antwort = await anAgent(
            a.agent.port,
            'POST',
            '/v1/restart',
            token: token,
          );
          expect(
            antwort.ok || antwort.code == errorRestartBusy,
            isTrue,
            reason: antwort.text,
          );
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (var k = 0; k < 3; k++) kasse(k),
    ]).timeout(const Duration(seconds: 90));

    // Jeder Bon genau einmal, unverschränkt, nie zwei Verbindungen zugleich.
    final druckeJeDrucker = <int>[
      erwartet.where((i) => i.endsWith('D0')).length,
      erwartet.where((i) => i.endsWith('D1')).length,
    ];
    for (var i = 0; i < 2; i++) {
      if (druckeJeDrucker[i] > 0) {
        await fakes[i].warteAufDruck(druckeJeDrucker[i] - 1);
      }
    }
    _jederBonGenauEinmal(fakes, erwartet);

    // Nie eine zweite Anfrage ans Terminal während einer Zahlung (außer der
    // Statusabfrage, die die Kasse dafür braucht).
    final zahlungen = hps.an('/api/transaction/payment');
    expect(zahlungen, hasLength(zahlungenOk));
    for (final z in zahlungen) {
      for (final anderer in hps.aufrufe) {
        if (identical(anderer, z) || anderer.pfad.startsWith('/api/v2/')) {
          continue;
        }
        final ueberlappt =
            anderer.beginn.isBefore(z.ende!) &&
            z.beginn.isBefore(anderer.ende!);
        expect(ueberlappt, isFalse, reason: '${anderer.pfad} neben Zahlung');
      }
    }

    // Status antwortet immer sofort.
    expect(langsamsterStatus, lessThan(const Duration(seconds: 1)));

    // Alle Sperren wieder frei, kein caffeinate übrig, Datei gültig.
    await warteBis(() async => !a.agent.context.vorgaenge!.laufen);
    await warteBis(() async => a.caffeinateGestartet == a.caffeinateBeendet);
    await warteBis(
      () async => !betriebLockDatei(a.temp).existsSync(),
      grund: 'betrieb.lock weg',
    );
    final roh = File(p.join(a.temp.path, 'config.json')).readAsStringSync();
    expect(jsonDecode(roh), isA<Map<String, Object?>>());
    expect((await a.store.load()).printers, hasLength(2));
  });
}
