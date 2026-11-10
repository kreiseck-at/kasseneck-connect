import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ablehnen.dart';
import 'support/agent_klient.dart';
import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';
import 'support/fake_process_runner.dart';

/// „Nie schlechter als 1.4.2“: was eine Neuerung nicht sicher entscheiden
/// kann, verhält sich wie 1.4.2 – Bytes, Antworten und Zeit.
void main() {
  late Directory temp;
  late ConfigStore store;
  late FakeProcessRunner prozesse;
  late Agent agent;
  late String token;
  late FakeTcpPrinter drucker;

  Future<void> starten({
    List<LocalInterface> netz = const <LocalInterface>[
      LocalInterface(name: 'lo0', address: '127.0.0.2'),
    ],
    SocketConnector? verbinden,
    bool bewiesen = false,
  }) async {
    agent = Agent(
      store: store,
      log: AgentLog(Directory(p.join(temp.path, 'logs'))),
      preferredPort: 0,
      openBrowser: false,
      environment: const <String, String>{},
      runProcess: prozesse.runner,
      startProcess: prozesse.starter,
      betriebssystem: 'macos',
      schnittstellen: () async => netz,
      geraeteVerbindung: verbinden,
      bewieseneModelle: bewiesen ? testModelle : const <BewiesenesModell>[],
    );
    await agent.start();
    token = await agent.context.pairing.issueToken();
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('connect-wie142-');
    store = ConfigStore.forDirectory(temp);
    prozesse = FakeProcessRunner();
    // Ein fremdes oder altes Gerät: antwortet auf nichts.
    drucker = await FakeTcpPrinter.start();
  });

  tearDown(() async {
    await agent.stop();
    await drucker.stop();
    temp.deleteSync(recursive: true);
  });

  Future<String> drucker142({
    String? serial,
    String? mac,
    bool bewiesen = false,
  }) async {
    final saved = await agent.printers.upsert(
      PrinterConfig(
        id: '',
        name: 'Bon',
        kind: PrinterKind.tcp9100,
        host: '127.0.0.1',
        port: drucker.port,
        model: bewiesen ? bewiesenesTestModell : null,
        modelSource: bewiesen ? KennungsQuelle.escpos : null,
        serial: serial,
        mac: mac,
      ),
    );
    return saved.id;
  }

  Future<AgentAntwort> drucke(String id, String jobId) => anAgent(
    agent.port,
    'POST',
    '/v1/print',
    token: token,
    rumpf: <String, Object?>{
      'printerId': id,
      'jobId': jobId,
      'bytes': base64Encode(beispielBon),
    },
  );

  test(
    'Modell nicht bewiesen (wie jeder Drucker bis zum Gerätetest): jede '
    'Verbindung trägt genau die Bytes der Kasse, keine Abfrage, kein ARP',
    () async {
      await starten();
      final id = await drucker142(
        serial: 'X5ZT000123',
        mac: '00:26:ab:00:00:01',
      );

      final erste = await drucke(id, 'beleg-1');
      expect(erste.ok, isTrue, reason: erste.text);
      expect(erste.json.keys, <String>['ok', 'jobId']);
      await drucke(id, 'beleg-2');
      await drucker.warteAufDruck(1);

      expect(drucker.verbindungen.map((v) => v.bytes), <List<int>>[
        beispielBon,
        beispielBon,
      ]);
      expect(prozesse.calls.where((c) => c.executable == 'arp'), isEmpty);
    },
  );

  test('bewiesenes Modell, aber stummes Gerät: höchstens eine '
      'Abfrage-Verbindung, nie GS I, der Zuschlag gedeckelt', () async {
    await starten(bewiesen: true);
    final id = await drucker142(serial: 'X5ZT000123', bewiesen: true);
    await drucke(id, 'beleg-1');
    await drucke(id, 'beleg-2');
    await drucker.warteAufDruck(1);
    expect(drucker.druckVerbindungen, <List<int>>[beispielBon, beispielBon]);
    // Die erste, danach gilt es als stumm; darauf nie GS I.
    expect(drucker.abfrageVerbindungen.single, dleEot(2));
    // Gedeckelt durch das Budget der Vorprüfung (Vorgabe: höchstens 600 ms),
    // nicht über eine Wanduhr am HTTP-Umlauf gemessen.
    expect(
      vorpruefungBudget,
      lessThanOrEqualTo(const Duration(milliseconds: 600)),
    );
  });

  test('Drucker in fremdem Netz mit Kennung: druckt, ohne ARP', () async {
    await starten(
      netz: const <LocalInterface>[
        LocalInterface(name: 'en0', address: '192.168.0.10'),
      ],
    );
    final id = await drucker142(mac: '00:26:ab:00:00:01');
    final antwort = await drucke(id, 'beleg-1');
    expect(antwort.ok, isTrue);
    await drucker.warteAufDruck(0);
    expect(drucker.druckVerbindungen.single, beispielBon);
    expect(prozesse.calls.where((c) => c.executable == 'arp'), isEmpty);
  });

  test(
    'alle Neuerungen aus: kein Byte außer dem Bon, kein arp, kein Takt',
    () async {
      await store.mutate(
        (c) => c.copyWith(
          disabledFeatures: Neuerung.values.map((n) => n.wireName).toList(),
        ),
      );
      await starten();
      final id = await drucker142(
        serial: 'X5ZT000123',
        mac: '00:26:ab:00:00:01',
      );
      drucker
        ..dleEot.addAll(const <int, int>{2: 0x32, 4: 0x72})
        ..gsI[68] = 'X5ZT000999';
      final antwort = await drucke(id, 'beleg-1');
      expect(
        antwort.ok,
        isTrue,
        reason: 'Papier leer zählt abgeschaltet nicht',
      );
      await drucker.warteAufDruck(0);
      expect(drucker.verbindungen.single.bytes, beispielBon);
      expect(prozesse.calls.where((c) => c.executable == 'arp'), isEmpty);
    },
  );

  group('eine Kasse, die nur 1.4.2 kennt', () {
    test('Status ohne Token: Felder aus 1.4.2 plus installationId', () async {
      await starten();
      final antwort = await anAgent(agent.port, 'GET', '/v1/status');
      expect(antwort.json.keys.toSet(), <String>{
        'ok',
        'version',
        'os',
        'port',
        'httpsPort',
        'paired',
        'uptimeSeconds',
        'features',
        'installationId',
      });
    });

    test('Drucker ohne Wissen: genau die Felder aus 1.4.2', () async {
      await starten();
      await store.mutate(
        (c) => c.copyWith(disabledFeatures: <String>['printer_identity']),
      );
      final antwort = await anAgent(
        agent.port,
        'PUT',
        '/v1/printers',
        token: token,
        rumpf: <String, Object?>{
          'kind': 'tcp9100',
          'host': '127.0.0.1',
          'port': drucker.port,
        },
      );
      expect((antwort.json['printer']! as Map<String, Object?>).keys, <String>[
        'id',
        'name',
        'kind',
        'host',
        'port',
        'state',
      ]);
      final liste = await anAgent(
        agent.port,
        'GET',
        '/v1/printers?probe=0',
        token: token,
      );
      final eintrag =
          (liste.json['printers']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(eintrag.keys, <String>[
        'id',
        'name',
        'kind',
        'host',
        'port',
        'state',
      ]);
    });

    test('Drucker aus: printer_offline mit derselben Form wie 1.4.2', () async {
      await starten(verbinden: verbindenOhneTote);
      final saved = await agent.printers.upsert(
        PrinterConfig(
          id: '',
          name: 'Bon',
          kind: PrinterKind.tcp9100,
          host: toteAdresse,
        ),
      );
      final antwort = await drucke(saved.id, 'beleg-1');
      expect(antwort.ok, isFalse);
      expect(antwort.code, errorPrinterOffline);
      expect(antwort.detail!['jobId'], 'beleg-1');
      expect(antwort.detail!.containsKey('mayHavePrinted'), isFalse);
    });
  });
}
