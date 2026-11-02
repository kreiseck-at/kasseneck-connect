import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/bluetooth_probe.dart';
import 'support/fake_bluetooth.dart';

void main() {
  group('parseHexText', () {
    test('liest Ziffern über Leerraum und Zeilen hinweg', () {
      final bytes = parseHexText('1b 40 0A\r\n  ff\t00\n\n7f');
      expect(bytes, Uint8List.fromList([0x1b, 0x40, 0x0a, 0xff, 0x00, 0x7f]));
    });

    test('Ziffern eines Bytes dürfen über Zeilen verteilt sein', () {
      // "1" und "b" stehen in verschiedenen Zeilen: gleiche Ziffernfolge wie
      // "1b" – die Goldens trennen Bytes nur durch Leerraum, der Parser
      // verlangt trotzdem eine gerade Gesamtzahl.
      expect(parseHexText('1\nb'), Uint8List.fromList([0x1b]));
    });

    test('ungerade Ziffernzahl nennt die Zeile des losen Zeichens', () {
      expect(
        () => parseHexText('1b 40\n0a ff\nabc'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Zeile 3'),
          ),
        ),
      );
    });

    test('fremdes Zeichen nennt Zeile und Zeichen', () {
      expect(
        () => parseHexText('1b 40\n0g'),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('Zeile 2'))
              .having((e) => e.message, 'message', contains('"g"')),
        ),
      );
    });

    test('leerer Text ergibt keine Bytes', () {
      expect(parseHexText(' \n\n'), isEmpty);
    });
  });

  group('splitPackets', () {
    test('teilt in Pakete und lässt den Rest kürzer', () {
      final pakete = splitPackets(
        Uint8List.fromList(List.generate(10, (i) => i)),
        4,
      );
      expect(pakete.map((x) => x.toList()), [
        [0, 1, 2, 3],
        [4, 5, 6, 7],
        [8, 9],
      ]);
    });

    test('genau ein Vielfaches ergibt kein leeres Schlusspaket', () {
      expect(splitPackets(Uint8List(8), 4), hasLength(2));
    });

    test('leere Daten ergeben keine Pakete, Größe 0 ist ein Fehler', () {
      expect(splitPackets(Uint8List(0), 4), isEmpty);
      expect(() => splitPackets(Uint8List(3), 0), throwsArgumentError);
    });

    test('hexOf trennt mit Leerzeichen', () {
      expect(hexOf([0x1a, 0x0f, 0x0c]), '1a 0f 0c');
    });
  });

  group('Argumente', () {
    test('Optionen und Standardwerte', () {
      final r = buildProbeParser().parse([
        '--token',
        't',
        'print',
        'id',
        'x.hex',
        '--ohne-antwort',
        '--paket',
        '20',
      ]);
      expect(r.rest, ['print', 'id', 'x.hex']);
      expect(r['token'], 't');
      expect(r['paket'], '20');
      expect(r['ohne-antwort'], isTrue);
      expect(r['warten'], '5');
      expect(r['http'], isFalse);
      expect(r['abbrechen-nach'], isNull);
    });

    test('ohne Befehl und mit unbekannter Option Exit 64', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      expect(await runProbe([], out: out, err: err), 64);
      expect(await runProbe(['--gibtsnicht'], out: out, err: err), 64);
      expect(err.toString(), contains('Fehler'));
    });

    test(
      'ohne Token Exit 64, ohne Agent Exit 1 (Token nie auf der Ausgabe)',
      () async {
        final out = StringBuffer();
        final err = StringBuffer();
        expect(await runProbe(['scan'], out: out, err: err), 64);
        expect(err.toString(), contains('--token'));

        final err2 = StringBuffer();
        expect(
          await runProbe(
            ['--token', 'geheim-123', '--http', '--port', '1', 'scan'],
            out: out,
            err: err2,
          ),
          1,
        );
        expect('$out$err2', isNot(contains('geheim-123')));
      },
    );
  });

  group('gegen einen echten Agenten (HTTP, Attrappe)', () {
    late Directory temp;
    late Agent agent;
    late FakeM110 m110;
    late FakeBluetoothHelper fake;
    late String tokenDatei;
    late String hexDatei;
    late List<String> basis;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('connect-probe-');
      final store = ConfigStore.forDirectory(temp);
      final log = AgentLog(Directory(p.join(temp.path, 'logs')));
      m110 = FakeM110(fertigNach: const Duration(milliseconds: 50));
      fake = FakeBluetoothHelper(log: log, geraete: [m110]);
      agent = Agent(
        store: store,
        log: log,
        preferredPort: 0,
        openBrowser: false,
        bluetoothHelper: fake,
      );
      await agent.start();
      final token = await agent.context.pairing.issueToken();
      tokenDatei = p.join(temp.path, 'token');
      File(tokenDatei).writeAsStringSync('$token\n');
      hexDatei = p.join(temp.path, 'beleg.bytes.hex');
      // 10 Byte in zwei Zeilen: bei Paketgröße 4 drei Pakete.
      File(hexDatei).writeAsStringSync('00 01 02 03 04\n05 06 07 08 09\n');
      basis = [
        '--token-datei',
        tokenDatei,
        '--http',
        '--port',
        '${agent.port}',
      ];
    });

    tearDown(() async {
      await agent.stop();
      temp.deleteSync(recursive: true);
    });

    Future<({int code, String out, String err})> lauf(
      List<String> args, {
      void Function(int)? hardExit,
      Stream<ProcessSignal>? interrupt,
    }) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runProbe(
        [...basis, ...args],
        out: out,
        err: err,
        hardExit: hardExit,
        interrupt: interrupt,
      );
      return (code: code, out: '$out', err: '$err');
    }

    test(
      'der Token erscheint nie auf der Ausgabe, auch nicht in Fehlern',
      () async {
        // Der unbekannte Befehl wird in der Fehlermeldung genannt – hier heißt er
        // wie der Token.
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runProbe(
          [
            '--token',
            'geheim-123',
            '--http',
            '--port',
            '${agent.port}',
            'geheim-123',
          ],
          out: out,
          err: err,
        );
        expect(code, 64);
        expect(err.toString(), contains('Unbekannter Befehl'));
        expect('$out$err', isNot(contains('geheim-123')));
      },
    );

    test('scan und approve', () async {
      final scan = await lauf(['scan']);
      expect(scan.code, 0, reason: scan.err);
      expect(scan.out, contains(fakeM110Id));

      final approve = await lauf([
        'approve',
        fakeM110Id,
        '--name',
        'Etikettendrucker',
      ]);
      expect(approve.code, 0, reason: approve.err);
      expect(approve.out, contains('Zugelassen'));
    });

    test(
      'print schreibt alle Pakete der Reihe nach, zeigt Meldungen und gibt frei',
      () async {
        expect((await lauf(['approve', fakeM110Id])).code, 0);

        final r = await lauf([
          'print',
          fakeM110Id,
          hexDatei,
          '--paket',
          '4',
          '--warten',
          '1',
        ]);
        expect(r.code, 0, reason: r.err);

        expect(m110.pakete.map((x) => x.toList()), [
          [0, 1, 2, 3],
          [4, 5, 6, 7],
          [8, 9],
        ]);
        expect(r.out, contains('Paket 3/3 geschrieben'));
        // Antworten auf ff02 (mit Antwort) und das Ende des Auftrags.
        expect(r.out, contains('Meldung ff03  01 01'));
        expect(r.out, contains('Meldung ff03  1a 0f 0c'));
        expect(r.out, contains('Belegung freigegeben (true)'));
        expect(r.out, matches(RegExp(r'\[\s*\d+ ms\]')));

        // Frei: ein Nächster bekommt die Belegung sofort.
        final bridge = agent.context.bluetooth!;
        final lease = await bridge.acquireLease(
          fakeM110Id,
          wait: Duration.zero,
        );
        expect(lease.id, isNotEmpty);
      },
    );

    test('--ohne-antwort schreibt ohne Antwort des Geräts', () async {
      expect((await lauf(['approve', fakeM110Id])).code, 0);
      final r = await lauf([
        'print',
        fakeM110Id,
        hexDatei,
        '--paket',
        '20',
        '--ohne-antwort',
        '--warten',
        '1',
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, isNot(contains('Meldung ff03  01 01')));
      expect(r.out, contains('Meldung ff03  1a 0f 0c'));
    });

    test('--abbrechen-nach endet hart ohne Freigabe', () async {
      expect((await lauf(['approve', fakeM110Id])).code, 0);

      final codes = <int>[];
      final r = await lauf([
        'print',
        fakeM110Id,
        hexDatei,
        '--paket',
        '4',
        '--abbrechen-nach',
        '2',
      ], hardExit: codes.add);
      expect(codes, [2]);
      expect(r.out, contains('Abbruch nach 2 Paketen, ohne Freigabe'));
      expect(r.out, isNot(contains('Belegung freigegeben')));

      expect(m110.pakete.map((x) => x.toList()), [
        [0, 1, 2, 3],
        [4, 5, 6, 7],
      ]);
      // Belegung bleibt stehen (der Agent setzt sie erst nach 5 s zurück).
      final bridge = agent.context.bluetooth!;
      await expectLater(
        bridge.acquireLease(
          fakeM110Id,
          wait: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<BluetoothFailure>().having(
            (e) => e.code,
            'code',
            'bluetooth_busy',
          ),
        ),
      );
    });

    test('Strg-C beim Senden endet hart ohne Freigabe', () async {
      expect((await lauf(['approve', fakeM110Id])).code, 0);
      final strgC = StreamController<ProcessSignal>();
      final codes = <int>[];

      // Kurze Wartezeit nach dem Senden: Strg-C trifft das Programm dort.
      final aufruf = lauf(
        ['print', fakeM110Id, hexDatei, '--warten', '2'],
        hardExit: codes.add,
        interrupt: strgC.stream,
      );
      final ende = DateTime.now().add(const Duration(seconds: 5));
      while (m110.pakete.isEmpty && DateTime.now().isBefore(ende)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      strgC.add(ProcessSignal.sigint);
      final r = await aufruf;
      expect(codes, [130]);
      expect(r.out, contains('Strg-C: Ende ohne Freigabe'));
      expect(r.out, isNot(contains('Belegung freigegeben')));

      final bridge = agent.context.bluetooth!;
      await expectLater(
        bridge.acquireLease(
          fakeM110Id,
          wait: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<BluetoothFailure>().having(
            (e) => e.code,
            'code',
            'bluetooth_busy',
          ),
        ),
      );
      await strgC.close();
    });

    test('watch schreibt Ereignisse mit und endet mit Strg-C', () async {
      expect((await lauf(['approve', fakeM110Id])).code, 0);
      final strgC = StreamController<ProcessSignal>();
      final aufruf = lauf(['watch', fakeM110Id], interrupt: strgC.stream);

      // Warten, bis das Abo steht, dann ein Etikett über die Brücke drucken.
      final ende = DateTime.now().add(const Duration(seconds: 5));
      while (!m110.abonniert && DateTime.now().isBefore(ende)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final bridge = agent.context.bluetooth!;
      final lease = await bridge.acquireLease(fakeM110Id);
      await bridge.write(
        fakeM110Id,
        '0000ff00-0000-1000-8000-00805f9b34fb',
        '0000ff02-0000-1000-8000-00805f9b34fb',
        [
          Uint8List.fromList([1, 2, 3]),
        ],
        withResponse: true,
        lease: lease.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      strgC.add(ProcessSignal.sigint);

      final r = await aufruf;
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('Meldung ff03  1a 0f 0c'));
      expect(r.out, contains('Ende.'));
      await strgC.close();
    });

    test(
      'koppeln schreibt den Token in eine Datei und druckt ihn nie',
      () async {
        final code = await agent.context.pairing.newCode();
        final datei = p.join(temp.path, 'neu', 'token');
        final out = StringBuffer();
        final err = StringBuffer();
        final exit = await runProbe(
          [
            'koppeln',
            code,
            '--token-datei',
            datei,
            '--http',
            '--port',
            '${agent.port}',
          ],
          out: out,
          err: err,
        );
        expect(exit, 0, reason: '$err');
        final token = File(datei).readAsStringSync().trim();
        expect(token, isNotEmpty);
        expect('$out$err', isNot(contains(token)));
        if (!Platform.isWindows) {
          expect(File(datei).statSync().mode & 0x1ff, 0x180); // 0600
        }
      },
    );
  });
}
