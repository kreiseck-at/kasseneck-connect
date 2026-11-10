import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/fake_printer.dart';
import 'support/port_zu.dart';

/// Antworten eines gesunden Epson-TM (Papier da, Deckel zu).
const Map<int, int> gesund = <int, int>{2: 0x12, 4: 0x12};

void main() {
  late FakeTcpPrinter drucker;
  final abfrage = EscPosAbfrage();

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
    final uhr = Stopwatch()..start();
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: EscPosFrage.values.toSet(),
      budget: const Duration(seconds: 2),
    );
    expect(uhr.elapsed, lessThan(handshakeFrist * 3));
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
    await drucker.ruhigNachVerbindung();
    expect(drucker.received, isEmpty);
  });

  test('Bytes ohne feste Bits werden übergangen, nie gedeutet', () async {
    drucker = await FakeTcpPrinter.start(dleEot: <int, int>{2: 0x10});
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.seriennummer},
      budget: const Duration(milliseconds: 200),
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
    drucker = await FakeTcpPrinter.start(dleEot: gesund)
      ..antwortVerzug = const Duration(seconds: 2);
    final uhr = Stopwatch()..start();
    final antworten = await abfrage.frage(
      '127.0.0.1',
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.rollensensor},
      budget: const Duration(milliseconds: 150),
    );
    // Deutlich vor der Antwort zurück – auch unter Last.
    expect(uhr.elapsed, lessThan(const Duration(seconds: 1)));
    expect(antworten.offlineGrund, isNull);
  });

  test('keine Verbindung: ohneVerbindung, wirft nicht', () async {
    drucker = await FakeTcpPrinter.start();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    await erwartePortZu(() => Socket.connect('127.0.0.1', port));
    final antworten = await abfrage.frage(
      '127.0.0.1',
      port,
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
      budget: const Duration(milliseconds: 300),
    );
    expect(antworten.offlineGrund, isNull);
    expect(antworten.seriennummer, isNull);
  });
}
