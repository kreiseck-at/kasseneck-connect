import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/fake_epos.dart';
import 'support/fake_printer.dart';

/// Liefert einen Port, auf dem sicher niemand lauscht.
Future<int> closedPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

void main() {
  group('Tcp9100Printer', () {
    test('schickt die Bytes unverändert an den Drucker', () async {
      final fake = await FakeTcpPrinter.start();
      addTearDown(fake.stop);

      final printer = Tcp9100Printer('127.0.0.1', fake.port);
      await printer.print(Uint8List.fromList(<int>[0x1b, 0x40, 65, 66, 10]));

      // Der Drucker sieht den Bytestrom erst, wenn die Verbindung zu ist.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.received, <int>[0x1b, 0x40, 65, 66, 10]);
      expect(fake.connections, 1);
    });

    test('geschlossener Port ergibt printer_offline', () async {
      final printer = Tcp9100Printer('127.0.0.1', await closedPort());

      await expectLater(
        printer.print(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(
          isA<PrinterFailure>()
              .having((f) => f.code, 'code', errorPrinterOffline)
              .having((f) => f.mayHavePrinted, 'mayHavePrinted', isFalse)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('ein Drucker, der nicht liest, läuft ins Zeitlimit', () async {
      final fake = await FakeTcpPrinter.start(mode: FakePrinterMode.hang);
      addTearDown(fake.stop);

      final printer = Tcp9100Printer('127.0.0.1', fake.port);
      final failure = await printer
          .print(
            Uint8List(8 * 1024 * 1024),
            timeout: const Duration(milliseconds: 400),
          )
          .then<PrinterFailure?>((_) => null)
          .onError<PrinterFailure>((e, _) => e);

      expect(failure?.code, errorPrintTimeout);
      expect(
        failure?.mayHavePrinted,
        isTrue,
        reason: 'die Bytes waren schon unterwegs',
      );
      expect(failure?.retryable, isFalse);
      expect(failure?.message, contains('bitte prüfen'));
    });

    test('abgebrochene Verbindung ergibt printer_offline', () async {
      final fake = await FakeTcpPrinter.start(mode: FakePrinterMode.reset);
      addTearDown(fake.stop);

      final printer = Tcp9100Printer('127.0.0.1', fake.port);
      final failure = await printer
          .print(Uint8List(8 * 1024 * 1024))
          .then<PrinterFailure?>((_) => null)
          .onError<PrinterFailure>((e, _) => e);

      expect(failure?.code, errorPrinterOffline);
      expect(failure?.mayHavePrinted, isTrue, reason: 'nach dem ersten add');
    });

    test('status meldet online bzw. offline', () async {
      final fake = await FakeTcpPrinter.start();
      addTearDown(fake.stop);

      expect(
        await Tcp9100Printer('127.0.0.1', fake.port).status(),
        PrinterState.online,
      );
      expect(
        await Tcp9100Printer('127.0.0.1', await closedPort()).status(),
        PrinterState.offline,
      );
    });
  });

  group('EposPrinter', () {
    test('baut die Adresse nach ePOS-Print', () {
      expect(
        EposPrinter('192.168.0.7').endpoint.toString(),
        'http://192.168.0.7/cgi-bin/epos/service.cgi'
        '?devid=local_printer&timeout=10000',
      );
      expect(
        EposPrinter(
          '192.168.0.7',
          port: 8043,
          https: true,
          devid: 'local_printer2',
        ).endpoint.toString(),
        'https://192.168.0.7:8043/cgi-bin/epos/service.cgi'
        '?devid=local_printer2&timeout=10000',
      );
    });

    test('schickt die Bytes base64 im SOAP-Rumpf', () async {
      final fake = await FakeEposServer.start();
      addTearDown(fake.stop);

      final printer = EposPrinter('127.0.0.1', port: fake.port);
      final bytes = Uint8List.fromList(<int>[0x1b, 0x40, 72, 73]);
      await printer.print(bytes);

      expect(fake.requests.single.path, '/cgi-bin/epos/service.cgi');
      expect(fake.requests.single.queryParameters['devid'], 'local_printer');
      expect(fake.requests.single.queryParameters['timeout'], '10000');
      expect(fake.headers.single['content-type'], contains('text/xml'));
      expect(fake.headers.single['soapaction'], '""');
      expect(
        fake.bodies.single,
        contains(
          '<epos-print xmlns="http://www.epson-pos.com/schemas/2011/03/'
          'epos-print">',
        ),
      );
      expect(fake.bodies.single, contains(base64Encode(bytes)));
      expect(fake.lastCommand, bytes);
    });

    test('success="false" ergibt refused samt Statuscode', () async {
      final fake = await FakeEposServer.start(mode: FakeEposMode.failure);
      addTearDown(fake.stop);

      final failure = await EposPrinter('127.0.0.1', port: fake.port)
          .print(Uint8List.fromList(<int>[1]))
          .then<PrinterFailure?>((_) => null)
          .onError<PrinterFailure>((e, _) => e);

      expect(failure?.code, errorPrintRefused);
      expect('${failure?.detail}', contains('EPTR_REC_EMPTY'));
      expect(failure?.retryable, isFalse, reason: 'das Gerät hat geantwortet');
    });

    test('HTTP 500 ergibt printer_offline', () async {
      final fake = await FakeEposServer.start(mode: FakeEposMode.serverError);
      addTearDown(fake.stop);

      final failure = await EposPrinter('127.0.0.1', port: fake.port)
          .print(Uint8List.fromList(<int>[1]))
          .then<PrinterFailure?>((_) => null)
          .onError<PrinterFailure>((e, _) => e);

      expect(failure?.code, errorPrinterOffline);
    });

    test('zu langsame Antwort ergibt timeout', () async {
      final fake = await FakeEposServer.start(
        mode: FakeEposMode.slow,
        delay: const Duration(seconds: 5),
      );
      addTearDown(fake.stop);

      final failure = await EposPrinter('127.0.0.1', port: fake.port)
          .print(
            Uint8List.fromList(<int>[1]),
            timeout: const Duration(milliseconds: 300),
          )
          .then<PrinterFailure?>((_) => null)
          .onError<PrinterFailure>((e, _) => e);

      expect(failure?.code, errorPrintTimeout);
      expect(
        failure?.mayHavePrinted,
        isTrue,
        reason: 'die Anfrage war schon raus',
      );
      expect(failure?.retryable, isFalse);
    });

    test('nicht erreichbarer Dienst ergibt printer_offline', () async {
      final printer = EposPrinter('127.0.0.1', port: await closedPort());

      final failure = await printer
          .print(Uint8List.fromList(<int>[1]))
          .then<PrinterFailure?>((_) => null)
          .onError<PrinterFailure>((e, _) => e);

      expect(failure?.code, errorPrinterOffline);
      expect(
        failure?.mayHavePrinted,
        isFalse,
        reason: 'ohne Verbindung ging nichts hinaus',
      );
      expect(failure?.retryable, isTrue);
    });

    test('die Attribute werden mit Wortgrenze gelesen', () {
      final result = parseEposResponse(
        '<response xmlns="x" errorcode="FALSCH" success="false" '
        'code="EPTR_COVER_OPEN" status="12" />',
      );

      expect(result?.success, isFalse);
      expect(result?.code, 'EPTR_COVER_OPEN');
      expect(result?.status, '12');
      expect(parseEposResponse('<kein-response/>'), isNull);
    });

    test('status fragt denselben Endpunkt ohne Druckdaten ab', () async {
      final fake = await FakeEposServer.start();
      addTearDown(fake.stop);

      final state = await EposPrinter('127.0.0.1', port: fake.port).status();

      expect(state, PrinterState.online);
      expect(fake.bodies.single, isNot(contains('<command>')));
      expect(
        await EposPrinter('127.0.0.1', port: await closedPort()).status(),
        PrinterState.offline,
      );
    });
  });
}
