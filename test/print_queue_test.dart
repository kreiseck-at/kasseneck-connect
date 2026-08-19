import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Treiber mit Drehbuch: je Versuch entweder Erfolg, ein Fehler oder Hängen.
class ScriptedDriver implements PrinterDriver {
  ScriptedDriver({List<PrinterFailure?>? script, this.hang = false})
    : _script = script ?? <PrinterFailure?>[];

  /// Wie oft die Warteschlange den laufenden Versuch abgebrochen hat.
  int aborts = 0;

  final List<PrinterFailure?> _script;

  /// Antwortet nie (prüft das Zeitlimit der Warteschlange).
  final bool hang;

  /// Wie viele Bytefolgen wirklich hinausgingen.
  final List<Uint8List> printed = <Uint8List>[];

  /// Versuche insgesamt (auch die fehlgeschlagenen).
  int attempts = 0;

  /// Verzögerung je Versuch — für die Prüfung der Reihenfolge.
  Duration delay = Duration.zero;

  /// Protokoll der Ein- und Austritte, um Verschachtelung zu erkennen.
  final List<String> trace = <String>[];

  @override
  Future<void> print(
    Uint8List bytes, {
    Duration timeout = defaultPrintTimeout,
  }) async {
    final index = attempts++;
    trace.add('start:$index');
    if (hang) return Completer<void>().future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final failure = index < _script.length ? _script[index] : null;
    trace.add('end:$index');
    if (failure != null) throw failure;
    printed.add(bytes);
  }

  @override
  Future<PrinterState> status({Duration timeout = defaultPrintTimeout}) async =>
      PrinterState.online;

  @override
  Future<void> abort() async {
    aborts++;
    trace.add('abort');
  }
}

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late EventBus bus;
  late List<AgentEvent> events;
  late StreamSubscription<AgentEvent> subscription;
  late DateTime now;

  final bytes = Uint8List.fromList(<int>[0x1b, 0x40, 65]);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-queue-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    bus = EventBus();
    events = <AgentEvent>[];
    subscription = bus.stream.listen(events.add);
    now = DateTime(2026, 8, 19, 12);
  });

  tearDown(() async {
    await subscription.cancel();
    await bus.close();
    temp.deleteSync(recursive: true);
  });

  /// Baut Registry + Warteschlange mit festen Treibern je Drucker.
  Future<(PrinterRegistry, PrintQueue)> build(
    Map<String, ScriptedDriver> drivers, {
    Duration jobTimeout = const Duration(seconds: 10),
    Duration attemptGrace = const Duration(milliseconds: 80),
    PrinterRegistry Function(PrinterDriver Function(PrinterConfig))?
    makeRegistry,
  }) async {
    PrinterDriver factory(PrinterConfig printer) => drivers[printer.name]!;
    final registry =
        makeRegistry?.call(factory) ??
        PrinterRegistry(
          store: store,
          log: log,
          events: bus,
          random: Random(1),
          driverFactory: factory,
        );
    for (final name in drivers.keys) {
      await registry.upsert(
        PrinterConfig(
          id: name,
          name: name,
          kind: PrinterKind.tcp9100,
          host: '10.0.0.1',
        ),
      );
    }
    final queue = PrintQueue(
      registry: registry,
      events: bus,
      log: log,
      clock: () => now,
      jobTimeout: jobTimeout,
      attemptGrace: attemptGrace,
    );
    return (registry, queue);
  }

  test(
    'unbekannter Drucker ergibt printer_unknown ohne Druckversuch',
    () async {
      final driver = ScriptedDriver();
      final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

      final result = await queue.enqueue('p_gibtsnicht', 'job1', bytes);

      expect(result.ok, isFalse);
      expect(result.code, errorPrinterUnknown);
      expect(driver.attempts, 0);

      // Der unbekannte Drucker ist kein Ergebnis, das die Idempotenz merkt.
      expect((await queue.enqueue('a', 'job1', bytes)).ok, isTrue);
    },
  );

  test('erfolgreicher Druck meldet print.done', () async {
    final driver = ScriptedDriver();
    final (registry, queue) = await build(<String, ScriptedDriver>{
      'a': driver,
    });

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.ok, isTrue);
    expect(driver.printed.single, bytes);
    expect(registry.stateOf('a'), PrinterState.online);
    await pumpEventQueue();
    final done = events.firstWhere((e) => e.type == eventPrintDone);
    expect(done.toJson()['jobId'], 'job1');
    expect(done.toJson()['printerId'], 'a');
  });

  test('Aufträge desselben Druckers laufen nacheinander', () async {
    final driver = ScriptedDriver()..delay = const Duration(milliseconds: 60);
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final first = queue.enqueue('a', 'job1', bytes);
    final second = queue.enqueue('a', 'job2', bytes);
    await Future.wait(<Future<PrintResult>>[first, second]);

    expect(driver.trace, <String>['start:0', 'end:0', 'start:1', 'end:1']);
  });

  test('verschiedene Drucker blockieren einander nicht', () async {
    final slow = ScriptedDriver()..delay = const Duration(milliseconds: 120);
    final quick = ScriptedDriver();
    final (_, queue) = await build(<String, ScriptedDriver>{
      'a': slow,
      'b': quick,
    });

    final first = queue.enqueue('a', 'job1', bytes);
    final second = await queue.enqueue('b', 'job2', bytes);

    expect(second.ok, isTrue);
    expect(slow.trace, <String>['start:0'], reason: 'a läuft noch');
    await first;
  });

  test('derselbe jobId druckt im Zeitfenster kein zweites Mal', () async {
    final driver = ScriptedDriver();
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final first = await queue.enqueue('a', 'job1', bytes);
    now = now.add(const Duration(seconds: 59));
    final second = await queue.enqueue('a', 'job1', bytes);

    expect(first.ok, isTrue);
    expect(second.ok, isTrue);
    expect(driver.attempts, 1);
    await pumpEventQueue();
    expect(events.where((e) => e.type == eventPrintDone), hasLength(1));
  });

  test(
    'nach 60 Sekunden gilt derselbe jobId wieder als neuer Auftrag',
    () async {
      final driver = ScriptedDriver();
      final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

      await queue.enqueue('a', 'job1', bytes);
      now = now.add(const Duration(seconds: 61));
      await queue.enqueue('a', 'job1', bytes);

      expect(driver.attempts, 2);
    },
  );

  test('laufender jobId wird nicht doppelt gedruckt', () async {
    final driver = ScriptedDriver()..delay = const Duration(milliseconds: 80);
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final first = queue.enqueue('a', 'job1', bytes);
    final second = await queue.enqueue('a', 'job1', bytes);

    expect(second.ok, isFalse);
    expect(second.code, errorPrintInProgress);
    expect((await first).ok, isTrue);
    expect(driver.attempts, 1);
  });

  // Ein sauberer Fehlschlag ist gesicherte Lage: es ist nichts hinausgegangen.
  // Die Kasse schickt denselben Auftrag nach dem Papiernachlegen mit derselben
  // `jobId` — hielte das Gedächtnis daran fest, bliebe der Bon eine Minute
  // lang unerreichbar, ohne dass jemand versteht, warum.
  test('ein sauber gescheiterter Auftrag darf es erneut versuchen', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(errorPrintRefused, 'Kein Papier.'),
      ],
    );
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final first = await queue.enqueue('a', 'job1', bytes);
    // Papier nachgelegt, gleiche jobId, kein Zeitsprung.
    final second = await queue.enqueue('a', 'job1', bytes);

    expect(first.code, errorPrintRefused);
    expect(second.ok, isTrue, reason: 'jetzt geht der Bon durch');
    expect(driver.attempts, 2);
    expect(driver.printed, hasLength(1));
  });

  test('ein Fehler mit offenem Ausgang bleibt dagegen gemerkt', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(
          errorPrintTimeout,
          unconfirmedPrintMessage,
          mayHavePrinted: true,
        ),
      ],
    );
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final first = await queue.enqueue('a', 'job1', bytes);
    final second = await queue.enqueue('a', 'job1', bytes);

    expect(first.code, errorPrintTimeout);
    expect(second.code, errorPrintTimeout, reason: 'dasselbe Ergebnis');
    expect(
      driver.attempts,
      1,
      reason: 'der Bon könnte gelaufen sein — kein zweiter blind hinterher',
    );
  });

  // Ohne den Zusatz des Treibers steht in Log und Antwort nur „printer_offline",
  // und Kasse wie Support raten, was das Gerät eigentlich gesagt hat.
  test('der Zusatz des Treibers steht im Log und in der Antwort', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(
          errorPrintRefused,
          'Der Drucker lehnt ab.',
          detail: 'code=EPTR_COVER_OPEN status=252',
        ),
      ],
    );
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.code, errorPrintRefused);
    expect(result.detail?['reason'], 'code=EPTR_COVER_OPEN status=252');
    expect(
      log.file.readAsStringSync(),
      contains('Auftrag job1 an a: refused (code=EPTR_COVER_OPEN status=252)'),
    );
  });

  test('Transportfehler wird genau einmal wiederholt', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(errorPrinterOffline, 'Weg.'),
        null,
      ],
    );
    final (registry, queue) = await build(<String, ScriptedDriver>{
      'a': driver,
    });

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.ok, isTrue);
    expect(driver.attempts, 2);
    expect(registry.stateOf('a'), PrinterState.online);
  });

  test(
    'zwei Transportfehler ergeben den Fehler des zweiten Versuchs',
    () async {
      final driver = ScriptedDriver(
        script: <PrinterFailure?>[
          const PrinterFailure(errorPrinterOffline, 'Weg.'),
          const PrinterFailure(errorPrinterOffline, 'Immer noch weg.'),
        ],
      );
      final (registry, queue) = await build(<String, ScriptedDriver>{
        'a': driver,
      });

      final result = await queue.enqueue('a', 'job1', bytes);

      expect(result.ok, isFalse);
      expect(result.code, errorPrinterOffline);
      expect(result.message, 'Immer noch weg.');
      expect(driver.attempts, 2);
      expect(registry.stateOf('a'), PrinterState.offline);
      await pumpEventQueue();
      final failed = events.firstWhere((e) => e.type == eventPrintFailed);
      expect(failed.toJson()['code'], errorPrinterOffline);
      expect(failed.toJson()['jobId'], 'job1');
    },
  );

  test('refused wird NICHT wiederholt', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(errorPrintRefused, 'Deckel offen.'),
        null,
      ],
    );
    final (registry, queue) = await build(<String, ScriptedDriver>{
      'a': driver,
    });

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.code, errorPrintRefused);
    expect(driver.attempts, 1, reason: 'das Gerät hat geantwortet');
    expect(
      registry.stateOf('a'),
      PrinterState.online,
      reason: 'ein ablehnendes Gerät ist erreichbar',
    );
  });

  test('ein Zeitlimit vor dem Senden wird wiederholt', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(errorPrintTimeout, 'Kein Verbindungsaufbau.'),
        null,
      ],
    );
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.ok, isTrue);
    expect(driver.attempts, 2);
    expect(driver.aborts, 1, reason: 'erst abbrechen, dann neu ansetzen');
    expect(driver.trace, <String>[
      'start:0',
      'end:0',
      'abort',
      'start:1',
      'end:1',
    ]);
  });

  test('ein Zeitlimit NACH dem Senden wird nicht wiederholt', () async {
    final driver = ScriptedDriver(
      script: <PrinterFailure?>[
        const PrinterFailure(
          errorPrintTimeout,
          unconfirmedPrintMessage,
          mayHavePrinted: true,
        ),
        null,
      ],
    );
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.code, errorPrintTimeout);
    expect(driver.attempts, 1, reason: 'der Bon könnte schon gelaufen sein');
    expect(driver.aborts, 0);
    expect(result.detail, <String, Object?>{'mayHavePrinted': true});
    expect(result.message, contains('bitte prüfen'));
    await pumpEventQueue();
    final failed = events.firstWhere((e) => e.type == eventPrintFailed);
    expect(failed.toJson()['mayHavePrinted'], isTrue);
  });

  test('ein hängender Treiber wird nicht wiederholt', () async {
    final driver = ScriptedDriver(hang: true);
    final (_, queue) = await build(
      <String, ScriptedDriver>{'a': driver},
      jobTimeout: const Duration(milliseconds: 100),
      attemptGrace: const Duration(milliseconds: 50),
    );

    final result = await queue.enqueue('a', 'job1', bytes);

    expect(result.code, errorPrintTimeout);
    expect(driver.attempts, 1);
    expect(result.detail, <String, Object?>{'mayHavePrinted': true});
  });

  test('derselbe jobId an zwei Druckern druckt zweimal', () async {
    final kasse = ScriptedDriver();
    final kueche = ScriptedDriver();
    final (_, queue) = await build(<String, ScriptedDriver>{
      'a': kasse,
      'b': kueche,
    });

    final first = await queue.enqueue('a', 'bon-1', bytes);
    final second = await queue.enqueue('b', 'bon-1', bytes);

    expect(first.ok, isTrue);
    expect(second.ok, isTrue);
    expect(kasse.printed, hasLength(1));
    expect(kueche.printed, hasLength(1), reason: 'die Küche druckt auch');
  });

  test(
    'ein Fehler in der Kette hängt weder Auftrag noch Drucker auf',
    () async {
      final driver = ScriptedDriver();
      final (_, queue) = await build(
        <String, ScriptedDriver>{'a': driver},
        makeRegistry: (factory) => FlakyRegistry(
          store: store,
          log: log,
          events: bus,
          random: Random(1),
          driverFactory: factory,
        ),
      );

      final broken = await queue
          .enqueue('a', 'job1', bytes)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError('Die Antwort blieb aus.'),
          );
      expect(broken.ok, isFalse);
      expect(broken.code, errorPrintInternal);

      // Der nächste Auftrag desselben Druckers läuft normal weiter.
      final next = await queue.enqueue('a', 'job2', bytes);
      expect(next.ok, isTrue);
      expect(driver.printed, hasLength(1));

      // Und derselbe jobId darf es nach dem Fehler noch einmal versuchen.
      expect((await queue.enqueue('a', 'job1', bytes)).ok, isTrue);
    },
  );

  test('forgetPrinter räumt Kette und Auftragsgedächtnis', () async {
    final driver = ScriptedDriver();
    final (_, queue) = await build(<String, ScriptedDriver>{'a': driver});

    await queue.enqueue('a', 'job1', bytes);
    queue.forgetPrinter('a');
    await queue.enqueue('a', 'job1', bytes);

    expect(driver.attempts, 2, reason: 'das Gedächtnis ist weg');
  });
}

/// Registry, die beim ersten Zugriff stolpert.
class FlakyRegistry extends PrinterRegistry {
  FlakyRegistry({
    required super.store,
    super.log,
    super.events,
    super.random,
    super.driverFactory,
  });

  int calls = 0;

  @override
  Future<PrinterDriver?> driverForId(String id) async {
    if (calls++ == 0) throw StateError('Konfiguration kaputt');
    return super.driverForId(id);
  }
}
