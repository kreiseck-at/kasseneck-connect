import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/agent_klient.dart';
import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';
import 'support/fake_process_runner.dart';

/// `arp -n 127.0.0.1` am Mac, wenn der Fake-Drucker die erfundene MAC hätte.
const String _arpLoopback =
    '? (127.0.0.1) at 0:26:ab:0:0:1 on lo0 ifscope [ethernet]\n';

void main() {
  late Directory temp;
  late ConfigStore store;
  late FakeProcessRunner prozesse;
  late FakeTcpPrinter drucker;
  late Agent agent;
  late String token;
  var mdnsFunde = const <DiscoveredPrinter>[];

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-erkennung-');
    store = ConfigStore.forDirectory(temp);
    prozesse = FakeProcessRunner()..stdoutOf['-n'] = _arpLoopback;
    drucker = await FakeTcpPrinter.start(
      dleEot: const <int, int>{2: 0x12, 4: 0x12},
      gsI: const <int, String>{67: 'TM-m30III', 68: 'X5ZT000123'},
    );
    mdnsFunde = const <DiscoveredPrinter>[];
    agent = Agent(
      store: store,
      log: AgentLog(Directory(p.join(temp.path, 'logs'))),
      preferredPort: 0,
      openBrowser: false,
      environment: const <String, String>{},
      runProcess: prozesse.runner,
      startProcess: prozesse.starter,
      betriebssystem: 'macos',
      // Loopback gilt im Test als eigenes Netz, damit ARP zählt.
      schnittstellen: () async => const <LocalInterface>[
        LocalInterface(name: 'lo0', address: '127.0.0.2'),
      ],
      discovery: PrinterDiscovery(mdns: (_) async => mdnsFunde),
      // Das Modell des Fake-Druckers gilt hier als bewiesen.
      bewieseneModelle: const <BewiesenesModell>[
        BewiesenesModell(
          modell: 'TM-m30III',
          geraet: 'Fake-Drucker der Tests',
          datum: '2026-11-10',
          gemessen: 'nichts – nur für Tests',
        ),
      ],
    );
    await agent.start();
    token = await agent.context.pairing.issueToken();
  });

  tearDown(() async {
    await agent.stop();
    await drucker.stop();
    temp.deleteSync(recursive: true);
  });

  Future<String> anlegen({int? port, String kind = 'tcp9100'}) async {
    final antwort = await anAgent(
      agent.port,
      'PUT',
      '/v1/printers',
      token: token,
      rumpf: <String, Object?>{
        'kind': kind,
        'host': '127.0.0.1',
        'port': port ?? drucker.port,
        'name': 'Bon',
      },
    );
    expect(antwort.ok, isTrue, reason: antwort.text);
    final eintrag = antwort.json['printer']! as Map<String, Object?>;
    // Die Antwort hat die Form aus 1.4.2.
    expect(eintrag.keys, <String>[
      'id',
      'name',
      'kind',
      'host',
      'port',
      'state',
    ]);
    return eintrag['id']! as String;
  }

  Future<PrinterConfig> gespeichert(String id) async =>
      (await store.load()).printers.singleWhere((d) => d.id == id);

  Future<void> warteAufKennung(String id) => warteBis(
    () async => (await gespeichert(id)).hatKennung,
    grund: 'Kennung von $id',
  );

  test('PUT ermittelt Modell, Seriennummer und MAC im Hintergrund', () async {
    final id = await anlegen();
    await warteAufKennung(id);

    final eintrag = await gespeichert(id);
    expect(eintrag.model, 'TM-m30III');
    expect(eintrag.serial, 'X5ZT000123');
    expect(eintrag.mac, '00:26:ab:00:00:01');
    expect(eintrag.identitySource, KennungsQuelle.escpos);
    expect(eintrag.identifiedAt, isNotNull);

    final liste = await anAgent(
      agent.port,
      'GET',
      '/v1/printers?probe=0',
      token: token,
    );
    final identity =
        ((liste.json['printers']! as List<Object?>).single!
                as Map<String, Object?>)['identity']
            as Map<String, Object?>;
    expect(identity['model'], 'TM-m30III');
    expect(identity['serial'], 'X5ZT000123');
    expect(identity['mac'], '00:26:ab:00:00:01');
    // Die Abfrage lief über eine eigene Verbindung, nur Abfragen darauf.
    expect(drucker.druckVerbindungen, isEmpty);
    expect(drucker.abfrageVerbindungen, hasLength(1));
  });

  test('erneutes PUT derselben Adresse behält die Kennung', () async {
    final id = await anlegen();
    await warteAufKennung(id);
    final zweite = await anlegen();
    expect(zweite, id);
    expect((await gespeichert(id)).serial, 'X5ZT000123');
  });

  test('Kennungskonflikt: eine Neueinrichtung derselben Adresse übernimmt '
      'die Kennung des Geräts dort neu', () async {
    // Ohne MAC (ARP kennt das Gerät nicht): die Seriennummer ist die Kennung.
    prozesse.stdoutOf['-n'] = '127.0.0.1 (127.0.0.1) -- no entry\n';
    final id = await anlegen();
    await warteAufKennung(id);
    // Gerät getauscht: unter der Adresse nennt sich ein anderer Drucker.
    drucker.gsI[68] = 'X5ZT000999';
    final druck = await anAgent(
      agent.port,
      'POST',
      '/v1/print',
      token: token,
      rumpf: <String, Object?>{
        'printerId': id,
        'jobId': 'beleg-1',
        'bytes': base64Encode(beispielBon),
      },
    );
    expect(druck.ok, isTrue, reason: 'nie blockieren');
    expect(agent.printers.lagen.von(id).kennung, KennungsLage.konflikt);
    expect((await gespeichert(id)).serial, 'X5ZT000123');

    // Die Kasse richtet den Drucker dort neu ein: gewollt.
    expect(await anlegen(), id);
    await warteBis(
      () async => (await gespeichert(id)).serial == 'X5ZT000999',
      grund: 'neue Kennung von $id',
    );
    expect(agent.printers.lagen.von(id).kennung, isNot(KennungsLage.konflikt));
  });

  test('Verdrahtung S1: schweigt ein statusfähiger Drucker vor dem Bon, '
      'geht der Bon wie 1.4.2 hinaus – ohne Nachfrage danach und ohne '
      'Flackern', () async {
    final id = await anlegen();
    await warteBis(() async {
      final d = await gespeichert(id);
      return d.statusCapableAt != null &&
          d.modelSource == KennungsQuelle.escpos;
    }, grund: 'statusfähig und Modell gelesen');
    final status = await anAgent(
      agent.port,
      'POST',
      '/v1/printers/$id/status',
      token: token,
    );
    expect(status.ok, isTrue);
    drucker.dleEot.clear(); // Deckel auf
    final druck = await anAgent(
      agent.port,
      'POST',
      '/v1/print',
      token: token,
      rumpf: <String, Object?>{
        'printerId': id,
        'jobId': 'beleg-1',
        'bytes': base64Encode(beispielBon),
      },
    );
    expect(druck.ok, isTrue, reason: 'Schweigen hält keinen Bon auf');
    await drucker.warteAufDruck(0);
    final verbindungen = drucker.connections;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(drucker.connections, verbindungen, reason: 'keine Nachfrage');
    final liste = await anAgent(
      agent.port,
      'GET',
      '/v1/printers?probe=0',
      token: token,
    );
    final eintrag =
        (liste.json['printers']! as List<Object?>).single
            as Map<String, Object?>;
    expect(eintrag['readiness'], 'ready', reason: 'eine ändert nichts');
    expect(eintrag.containsKey('readinessHint'), isFalse);
  });

  test('PUT mit neuer Adresse verliert die Kennung', () async {
    final id = await anlegen();
    await warteAufKennung(id);
    final anderer = await FakeTcpPrinter.start();
    try {
      final antwort = await anAgent(
        agent.port,
        'PUT',
        '/v1/printers/$id',
        token: token,
        rumpf: <String, Object?>{
          'kind': 'tcp9100',
          'host': '127.0.0.1',
          'port': anderer.port,
        },
      );
      expect(antwort.ok, isTrue);
      final eintrag = await gespeichert(id);
      expect(eintrag.port, anderer.port);
      expect(eintrag.serial, isNull);
    } finally {
      await anderer.stop();
    }
  });

  test('mDNS-TXT aus der Suche fließt in die Kennung', () async {
    drucker.gsI.clear();
    mdnsFunde = <DiscoveredPrinter>[
      DiscoveredPrinter(
        host: '127.0.0.1',
        port: drucker.port,
        kind: PrinterKind.tcp9100,
        name: 'TM-m30III',
        model: 'TM-m30III',
        serial: 'X5ZT000124',
      ),
    ];
    final suche = await anAgent(
      agent.port,
      'POST',
      '/v1/printers/discover',
      token: token,
      rumpf: const <String, Object?>{},
    );
    final fund =
        (suche.json['printers']! as List<Object?>).single!
            as Map<String, Object?>;
    expect(fund['model'], 'TM-m30III');
    expect(fund['serial'], 'X5ZT000124');

    final id = await anlegen();
    await warteAufKennung(id);
    final eintrag = await gespeichert(id);
    expect(eintrag.serial, 'X5ZT000124');
    expect(eintrag.identitySource, KennungsQuelle.mdns);
  });

  test(
    'ohne Kennung: ein Druck erkennt nie – die Druckersuche trägt sie nach',
    () async {
      await store.mutate(
        (c) => c.copyWith(disabledFeatures: <String>['printer_identity']),
      );
      final id = await anlegen();
      // Abgeschaltet: kein Byte außer dem Druck an das Gerät.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(drucker.connections, 0);

      await store.mutate((c) => c.copyWith(disabledFeatures: <String>[]));
      for (var i = 0; i < 3; i++) {
        final druck = await anAgent(
          agent.port,
          'POST',
          '/v1/print',
          token: token,
          rumpf: <String, Object?>{
            'printerId': id,
            'jobId': 'beleg-$i',
            'bytes': base64Encode(<int>[0x1B, 0x40, 0x41, 0x0A]),
          },
        );
        expect(druck.ok, isTrue, reason: druck.text);
      }
      await drucker.warteAufDruck(2);
      expect(
        drucker.abfrageVerbindungen,
        isEmpty,
        reason: 'nie wegen eines Bons',
      );
      expect((await gespeichert(id)).hatKennung, isFalse);

      final suche = await anAgent(
        agent.port,
        'POST',
        '/v1/printers/discover',
        token: token,
        rumpf: const <String, Object?>{},
      );
      expect(suche.ok, isTrue);
      await warteAufKennung(id);
      final eintrag = await gespeichert(id);
      expect(eintrag.model, 'TM-m30III');
      expect(eintrag.modelSource, KennungsQuelle.escpos);
      expect(eintrag.serial, 'X5ZT000123');
    },
  );

  test('printer_identity aus: PUT fragt das Gerät nie', () async {
    await store.mutate(
      (c) => c.copyWith(disabledFeatures: <String>['printer_identity']),
    );
    final id = await anlegen();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(drucker.connections, 0);
    expect((await gespeichert(id)).hatKennung, isFalse);
    expect(prozesse.calls.where((c) => c.executable == 'arp'), isEmpty);
  });

  test('ein Drucker in fremdem Netz bekommt keine MAC', () async {
    await agent.stop();
    agent = Agent(
      store: store,
      log: AgentLog(Directory(p.join(temp.path, 'logs'))),
      preferredPort: 0,
      openBrowser: false,
      environment: const <String, String>{},
      runProcess: prozesse.runner,
      startProcess: prozesse.starter,
      betriebssystem: 'macos',
      schnittstellen: () async => const <LocalInterface>[
        LocalInterface(name: 'en0', address: '192.168.0.10'),
      ],
    );
    await agent.start();
    token = await agent.context.pairing.issueToken();
    final id = await anlegen();
    await warteAufKennung(id);
    final eintrag = await gespeichert(id);
    expect(eintrag.serial, 'X5ZT000123');
    expect(eintrag.mac, isNull);
    expect(prozesse.calls.where((c) => c.executable == 'arp'), isEmpty);
  });

  test('eine MAC, die auch unter einer anderen Adresse steht (Repeater mit '
      'MAC-NAT), wird nicht gespeichert', () async {
    prozesse.stdoutOf['-an'] =
        '$_arpLoopback'
        '? (127.0.0.9) at 0:26:ab:0:0:1 on lo0 ifscope [ethernet]\n';
    final id = await anlegen();
    await warteAufKennung(id);
    final eintrag = await gespeichert(id);
    expect(eintrag.serial, 'X5ZT000123');
    expect(eintrag.mac, isNull);
  });

  test(
    'steht sie nur unter der eigenen Adresse, wird sie gespeichert',
    () async {
      prozesse.stdoutOf['-an'] = _arpLoopback;
      final id = await anlegen();
      await warteBis(
        () async => (await gespeichert(id)).mac != null,
        grund: 'MAC von $id',
      );
      expect((await gespeichert(id)).mac, '00:26:ab:00:00:01');
    },
  );

  group('Kennungspflege', () {
    test(
      'nachAnlegen kommt zurück; zwei Anstöße teilen sich eine Abfrage',
      () async {
        final a = DruckAufbau.erstellen();
        addTearDown(a.aufraeumen);
        final id = await a.drucker(drucker.port);
        final pflege = Kennungspflege(
          store: a.store,
          queue: a.queue,
          lagen: a.registry.lagen,
          clock: () => a.jetzt,
          erkennung: DruckerErkennung(
            abfrage: EscPosAbfrage(),
            arp: a.arp,
            schnittstellen: () async => a.schnittstellen,
          ),
        );
        await Future.wait(<Future<void>>[
          pflege.nachAnlegen(id),
          pflege.nachAnlegen(id),
        ]).timeout(const Duration(seconds: 5));
        expect(drucker.abfrageVerbindungen, hasLength(1));
        expect((await a.store.load()).printers.single.serial, 'X5ZT000123');
      },
    );
  });
}
