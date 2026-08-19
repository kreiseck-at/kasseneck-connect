import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late PrinterRegistry registry;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-registry-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    registry = PrinterRegistry(store: store, log: log, random: Random(7));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  PrinterConfig sample({String id = '', String name = 'Kasse vorne'}) =>
      PrinterConfig(
        id: id,
        name: name,
        kind: PrinterKind.tcp9100,
        host: '192.168.0.50',
      );

  test('neue IDs sind kurz, zufällig und eindeutig', () {
    final ids = List<String>.generate(50, (_) => registry.newId());

    expect(ids.toSet(), hasLength(50));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^p_[a-z2-7]{8}$')));
    }
  });

  test(
    'upsert vergibt eine ID und schreibt sie in die Konfiguration',
    () async {
      final saved = await registry.upsert(sample());

      expect(saved.id, matches(RegExp(r'^p_[a-z2-7]{8}$')));
      expect(saved.port, 9100, reason: 'Standardport der Anbindung');

      final reloaded = await ConfigStore.forDirectory(temp).load();
      expect(reloaded.printers, hasLength(1));
      expect(reloaded.printers.single.id, saved.id);
      expect(reloaded.printers.single.host, '192.168.0.50');
    },
  );

  test(
    'upsert mit bekannter ID ersetzt den Eintrag an Ort und Stelle',
    () async {
      final first = await registry.upsert(sample());
      final second = await registry.upsert(
        PrinterConfig(
          id: 'p_zzzzzzzz',
          name: 'Küche',
          kind: PrinterKind.epos,
          host: '192.168.0.51',
        ),
      );
      await registry.upsert(first.copyWith(name: 'Kasse hinten'));

      final printers = await registry.list();
      expect(printers, hasLength(2));
      expect(printers.first.id, first.id);
      expect(printers.first.name, 'Kasse hinten');
      expect(printers.last.id, second.id);
    },
  );

  test('remove löscht nur den gemeinten Drucker', () async {
    final first = await registry.upsert(sample());
    final second = await registry.upsert(sample(name: 'Küche'));

    expect(await registry.remove('p_gibtsnicht'), isFalse);
    expect(await registry.remove(first.id), isTrue);

    final printers = await registry.list();
    expect(printers.map((e) => e.id), <String>[second.id]);
    final reloaded = await ConfigStore.forDirectory(temp).load();
    expect(reloaded.printers.single.id, second.id);
  });

  test('driverFor baut den passenden Treiber', () async {
    final tcp = registry.driverFor(sample(id: 'p_aaaaaaaa'));
    expect(tcp, isA<Tcp9100Printer>());
    expect((tcp as Tcp9100Printer).port, 9100);

    final epos = registry.driverFor(
      PrinterConfig(
        id: 'p_bbbbbbbb',
        name: 'Küche',
        kind: PrinterKind.epos,
        host: '192.168.0.51',
        port: 8043,
        devid: 'local_printer2',
      ),
    );
    expect(epos, isA<EposPrinter>());
    expect(
      (epos as EposPrinter).endpoint.toString(),
      'http://192.168.0.51:8043/cgi-bin/epos/service.cgi'
      '?devid=local_printer2&timeout=10000',
    );

    final secure =
        registry.driverFor(
              PrinterConfig(
                id: 'p_cccccccc',
                name: 'Küche',
                kind: PrinterKind.epos,
                host: '192.168.0.51',
                port: 443,
              ),
            )
            as EposPrinter;
    expect(secure.https, isTrue);
    expect(secure.endpoint.toString(), startsWith('https://192.168.0.51/'));
  });

  test('driverForId liefert null für unbekannte Drucker', () async {
    final saved = await registry.upsert(sample());

    expect(await registry.driverForId(saved.id), isA<Tcp9100Printer>());
    expect(await registry.driverForId('p_gibtsnicht'), isNull);
  });

  test('Zusammenfassung führt den zuletzt bekannten Zustand', () async {
    final saved = await registry.upsert(sample());

    var summaries = await registry.summaries();
    expect(summaries.single['id'], saved.id);
    expect(summaries.single['kind'], 'tcp9100');
    expect(summaries.single['state'], 'unknown');

    registry.noteState(saved.id, PrinterState.offline);
    summaries = await registry.summaries();
    expect(summaries.single['state'], 'offline');
  });

  test('Zustandswechsel meldet printer.state auf dem Ereignisbus', () async {
    final bus = EventBus();
    addTearDown(bus.close);
    final events = <AgentEvent>[];
    final subscription = bus.stream.listen(events.add);
    addTearDown(subscription.cancel);

    final tracked = PrinterRegistry(
      store: store,
      log: log,
      events: bus,
      random: Random(3),
    );
    final saved = await tracked.upsert(sample());

    tracked
      ..noteState(saved.id, PrinterState.online)
      ..noteState(saved.id, PrinterState.online)
      ..noteState(saved.id, PrinterState.offline);
    await Future<void>.delayed(Duration.zero);

    expect(events.map((e) => e.toJson()['state']), <String>[
      'online',
      'offline',
    ]);
    expect(events.first.type, eventPrinterState);
    expect(events.first.toJson()['printerId'], saved.id);
  });

  test(
    'summaries(probe: true) fragt die Geräte und merkt sich das Ergebnis',
    () async {
      final probing = PrinterRegistry(
        store: store,
        log: log,
        random: Random(5),
        driverFactory: (printer) => _StubDriver(
          printer.host == 'da' ? PrinterState.online : PrinterState.offline,
        ),
      );
      final online = await probing.upsert(
        sample(name: 'da').copyWith(host: 'da'),
      );
      final offline = await probing.upsert(
        sample(name: 'weg').copyWith(host: 'weg'),
      );

      final summaries = await probing.summaries(probe: true);

      expect(
        summaries.firstWhere((e) => e['id'] == online.id)['state'],
        'online',
      );
      expect(
        summaries.firstWhere((e) => e['id'] == offline.id)['state'],
        'offline',
      );
      expect(probing.stateOf(online.id), PrinterState.online);
    },
  );
}

/// Treiber, der einen festen Zustand meldet und nie wirklich druckt.
class _StubDriver implements PrinterDriver {
  _StubDriver(this.state);

  final PrinterState state;

  @override
  Future<void> print(
    Uint8List bytes, {
    Duration timeout = defaultPrintTimeout,
  }) async {}

  @override
  Future<PrinterState> status({Duration timeout = defaultPrintTimeout}) async =>
      state;

  @override
  Future<void> abort() async {}
}
