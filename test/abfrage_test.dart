import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/ablehnen.dart';
import 'support/fake_printer.dart';

/// Antworten eines gesunden Epson-TM (Papier da, Deckel zu).
const Map<int, int> gesund = <int, int>{2: 0x12, 4: 0x12};

void main() {
  late FakeTcpPrinter drucker;
  final abfrage = EscPosAbfrage();
  // Für Tests, die nachgewiesenes Schweigen erwarten: unter Last (`-j 8`)
  // steht eine Loopback-Verbindung nicht immer in 200 ms – dann wäre das
  // Schweigen zu Recht unbekannt, der Test aber rot.
  final geduldig = EscPosAbfrage(aufbauGrenze: const Duration(seconds: 1));

  tearDown(() => drucker.stop());

  test('fragt Status und Kennung über eine eigene Verbindung', () async {
    drucker = await FakeTcpPrinter.start(
      dleEot: gesund,
      gsI: <int, String>{67: 'TM-m30III', 68: 'X5ZT000123'},
    );
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: EscPosFrage.values.toSet(),
      budget: const Duration(seconds: 2),
    );
    expect(antworten.verbunden, isTrue);
    expect(antworten.stumm, isFalse);
    expect(antworten.offlineGrund, 0x12);
    expect(antworten.rollensensor, 0x12);
    expect(antworten.modell, 'TM-m30III');
    expect(antworten.seriennummer, 'X5ZT000123');
    expect(drucker.verbindungen, hasLength(1));
    expect(drucker.verbindungen.single.bytes, <int>[
      ...dleEot(2),
      ...dleEot(4),
      ...gsI(67),
      ...gsI(68),
    ]);
  });

  test('stummes Gerät: nur DLE EOT 2, nie GS I, nach der Handshake-Frist '
      'statt des ganzen Budgets', () async {
    drucker = await FakeTcpPrinter.start();
    // Mit einer Stunde Budget kehrt die Abfrage nur zurück, weil sie nach der
    // Handshake-Frist aufgibt – ohne Messung der Wanduhr.
    final antworten = await geduldig.frage(
      '127.0.0.1',
      drucker.port,
      fragen: EscPosFrage.values.toSet(),
      budget: const Duration(hours: 1),
    );
    expect(antworten.stumm, isTrue);
    expect(antworten.seriennummer, isNull);
    // Ein Bürodrucker auf 9100 bekäme sonst „ID“ als Seite.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(drucker.received, dleEot(2));
  });

  test('ohne Restzeit wird nicht mehr gefragt', () async {
    drucker = await FakeTcpPrinter.start(dleEot: gesund);
    // Der Verbindungsaufbau verbraucht das ganze Budget: danach darf keine
    // Frage mehr hinausgehen – gleich wie schnell der Rechner ist.
    final langsam = EscPosAbfrage(
      verbinden: (host, port, {timeout}) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return Socket.connect(host, port);
      },
    );
    final antworten = await langsam.frage(
      '127.0.0.1',
      drucker.port,
      fragen: EscPosFrage.values.toSet(),
      budget: const Duration(milliseconds: 100),
    );
    expect(antworten.verbunden, isTrue);
    expect(antworten.offlineGrund, isNull);
    // Nicht gefragt heißt unbekannt – nie „stumm“ und damit nie „nicht
    // bereit“.
    expect(antworten.stumm, isFalse);
    await drucker.ruhigNachVerbindung();
    expect(drucker.received, isEmpty);
  });

  test('langsamer Verbindungsaufbau: Schweigen danach ist unbekannt', () async {
    drucker = await FakeTcpPrinter.start();
    // Verlorenes SYN, WLAN wacht auf: die Verbindung steht erst spät. Danach
    // ist auch ein volles Antwortfenster kein Beweis.
    final langsam = EscPosAbfrage(
      verbinden: (host, port, {timeout}) async {
        await Future<void>.delayed(
          langsamerAufbau + const Duration(milliseconds: 50),
        );
        return Socket.connect(host, port);
      },
    );
    final antworten = await langsam.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
      budget: const Duration(seconds: 5),
    );
    expect(antworten.verbunden, isTrue);
    expect(antworten.offlineGrund, isNull);
    expect(antworten.stumm, isFalse);
    await drucker.ruhigNachVerbindung();
    expect(drucker.received, dleEot(2));
  });

  test(
    'Budget kürzer als das Antwortfenster: gefragt, aber nicht stumm',
    () async {
      drucker = await FakeTcpPrinter.start();
      final antworten = await abfrage.frage(
        '127.0.0.1',
        drucker.port,
        fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
        budget: handshakeFrist ~/ 2,
      );
      expect(antworten.verbunden, isTrue);
      expect(antworten.stumm, isFalse);
    },
  );

  test('Reserve kürzt das Antwortfenster: Schweigen ist unbekannt', () async {
    drucker = await FakeTcpPrinter.start();
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
      budget: const Duration(seconds: 1),
      handshake: bereitFrist,
      reserve: const Duration(milliseconds: 800),
    );
    expect(antworten.verbunden, isTrue);
    expect(antworten.stumm, isFalse);
  });

  test('ohne Budget: keine Verbindung und kein Verbindungsfehler', () async {
    drucker = await FakeTcpPrinter.start(dleEot: gesund);
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
      budget: Duration.zero,
    );
    expect(antworten.verbunden, isFalse);
    // Kein Verbindungsfehler: das zählt nie als erster Druckversuch.
    expect(antworten.verbindungsFehler, isNull);
    expect(drucker.connections, 0);
  });

  test('Bytes ohne feste Bits werden übergangen, nie gedeutet', () async {
    drucker = await FakeTcpPrinter.start(dleEot: <int, int>{2: 0x10});
    final antworten = await geduldig.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.seriennummer},
      budget: const Duration(seconds: 2),
    );
    expect(antworten.offlineGrund, isNull);
    expect(antworten.stumm, isTrue);
  });

  test('ungültiger GS-I-Rahmen ergibt keine Kennung', () async {
    drucker = await FakeTcpPrinter.start(dleEot: gesund);
    drucker.gsIRoh[68] = <int>[0x5F, 0x41, 0x07, 0x42, 0x00];
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.seriennummer},
      budget: const Duration(milliseconds: 500),
    );
    expect(antworten.offlineGrund, 0x12);
    expect(antworten.seriennummer, isNull);
  });

  test('Antwort nach dem Budget zählt nicht', () async {
    // Die Antwort käme erst nach einer Stunde: dass die Abfrage überhaupt
    // zurückkehrt, zeigt, dass sie am Budget endet.
    drucker = await FakeTcpPrinter.start(dleEot: gesund)
      ..antwortVerzug = const Duration(hours: 1);
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
      budget: const Duration(milliseconds: 150),
    );
    expect(antworten.offlineGrund, isNull);
    expect(antworten.stumm, isFalse);
  });

  test('keine Verbindung: ohneVerbindung, wirft nicht', () async {
    drucker = await FakeTcpPrinter.start();
    final antworten = await EscPosAbfrage(verbinden: verbindenOhneTote).frage(
      toteAdresse,
      9100,
      fragen: EscPosFrage.values.toSet(),
      budget: const Duration(milliseconds: 500),
    );
    expect(antworten.verbunden, isFalse);
    expect(antworten.verbindungsFehler, isA<SocketException>());
    expect(antworten.stumm, isFalse);
  });

  test('Gerät wirft die Verbindung weg: unbekannt, wirft nicht', () async {
    drucker = await FakeTcpPrinter.start(mode: FakePrinterMode.reset);
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: EscPosFrage.values.toSet(),
      budget: const Duration(seconds: 2),
    );
    expect(antworten.offlineGrund, isNull);
    expect(antworten.seriennummer, isNull);
    // Annehmen und sofort schließen (belegt, Neustart) ist kein Schweigen.
    expect(antworten.stumm, isFalse);
  });

  test(
    'die Reserve für den zweiten Versuch ist ein Aufbau plus ein Fenster',
    () {
      expect(zweiterVersuchReserve, bereitFrist + langsamerAufbau);
    },
  );

  group('frageBereit', () {
    test('beide Versuche schweigen: stumm, zwei Verbindungen', () async {
      drucker = await FakeTcpPrinter.start();
      final antworten = await geduldig.frageBereit(
        '127.0.0.1',
        drucker.port,
        fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
        budget: const Duration(seconds: 5),
      );
      expect(antworten.stumm, isTrue);
      await drucker.ruhigNachVerbindung();
      expect(drucker.verbindungen, hasLength(2));
    });

    test(
      'zweiter Versuch ohne volles Fenster: unbekannt statt stumm',
      () async {
        drucker = await FakeTcpPrinter.start();
        var n = 0;
        final abfrageZweiterLangsam = EscPosAbfrage(
          verbinden: (host, port, {timeout}) async {
            if (n++ > 0) {
              await Future<void>.delayed(
                langsamerAufbau + const Duration(milliseconds: 50),
              );
            }
            return Socket.connect(host, port);
          },
        );
        final antworten = await abfrageZweiterLangsam.frageBereit(
          '127.0.0.1',
          drucker.port,
          fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
          budget: vorpruefungBudgetStatusfaehig,
        );
        expect(antworten.verbunden, isTrue);
        expect(antworten.stumm, isFalse);
      },
    );

    test('der erste Versuch lässt dem zweiten seine Zeit', () async {
      drucker = await FakeTcpPrinter.start();
      // Ein Budget, in das zwei volle Fenster nicht passen: der erste Versuch
      // kürzt sein Fenster für die Reserve, sein Schweigen beweist nichts,
      // und ein zweiter Versuch ist nicht mehr nötig.
      final antworten = await abfrage.frageBereit(
        '127.0.0.1',
        drucker.port,
        fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
        budget: zweiterVersuchReserve + bereitFrist ~/ 2,
      );
      expect(antworten.stumm, isFalse);
      await drucker.ruhigNachVerbindung();
      expect(drucker.verbindungen, hasLength(1));
    });

    test('antwortet der Drucker, bleibt es bei einer Verbindung', () async {
      drucker = await FakeTcpPrinter.start(dleEot: gesund);
      final antworten = await abfrage.frageBereit(
        '127.0.0.1',
        drucker.port,
        fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
        budget: vorpruefungBudgetStatusfaehig,
      );
      expect(antworten.offlineGrund, 0x12);
      expect(antworten.rollensensor, 0x12);
      expect(drucker.verbindungen, hasLength(1));
    });
  });
}
