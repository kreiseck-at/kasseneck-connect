import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Ausgaben von `arp`, wie die drei Systeme sie schreiben (erfundene Werte).
const String _macos =
    '? (192.168.0.50) at 0:26:ab:0:0:1 on en0 ifscope [ethernet]\n';
const String _macosOhne = '192.168.0.51 (192.168.0.51) -- no entry\n';
const String _macosUnvollstaendig =
    '? (192.168.0.52) at (incomplete) on en0 ifscope [ethernet]\n';
const String _linux =
    'Address                  HWtype  HWaddress           Flags Mask  Iface\n'
    '192.168.0.50             ether   00:26:ab:00:00:01   C           eth0\n';
const String _windows =
    '\nInterface: 192.168.0.10 --- 0x4\n'
    '  Internet Address      Physical Address      Type\n'
    '  192.168.0.50          00-26-ab-00-00-01     dynamic\n'
    '  192.168.0.255         ff-ff-ff-ff-ff-ff     static\n';
const String _macosTabelle =
    '? (192.168.0.1) at 0:11:22:33:44:55 on en0 ifscope [ethernet]\n'
    '? (192.168.0.50) at 0:26:ab:0:0:1 on en0 ifscope [ethernet]\n'
    '? (192.168.0.61) at 0:26:ab:0:0:1 on en0 ifscope [ethernet]\n'
    '? (192.168.0.62) at (incomplete) on en0 ifscope [ethernet]\n';

void main() {
  group('Ausgabe lesen', () {
    test('macOS, Linux und Windows ergeben dieselbe MAC', () {
      for (final ausgabe in <String>[_macos, _linux, _windows]) {
        expect(
          macAusArpAusgabe(ausgabe, '192.168.0.50'),
          '00:26:ab:00:00:01',
          reason: ausgabe,
        );
      }
    });

    test('ohne Eintrag oder unvollständig: keine MAC', () {
      expect(macAusArpAusgabe(_macosOhne, '192.168.0.51'), isNull);
      expect(macAusArpAusgabe(_macosUnvollstaendig, '192.168.0.52'), isNull);
      expect(macAusArpAusgabe(_macos, '192.168.0.5'), isNull);
      expect(macAusArpAusgabe('', '192.168.0.50'), isNull);
    });

    test('die ganze Tabelle, ohne Rundsende-Adresse', () {
      expect(arpTabelleAusAusgabe(_macosTabelle), <String, String>{
        '192.168.0.1': '00:11:22:33:44:55',
        '192.168.0.50': '00:26:ab:00:00:01',
        '192.168.0.61': '00:26:ab:00:00:01',
      });
      expect(arpTabelleAusAusgabe(_windows), <String, String>{
        '192.168.0.50': '00:26:ab:00:00:01',
      });
    });
  });

  group('gleichesNetz', () {
    const eigene = <LocalInterface>[
      LocalInterface(name: 'en0', address: '192.168.0.10'),
    ];
    test('nur das /24 einer eigenen Schnittstelle zählt', () {
      expect(gleichesNetz('192.168.0.50', eigene), isTrue);
      expect(gleichesNetz('192.168.1.50', eigene), isFalse);
      expect(gleichesNetz('drucker.local', eigene), isFalse);
      expect(gleichesNetz('192.168.0.50', const <LocalInterface>[]), isFalse);
    });
  });

  group('ArpTabelle', () {
    late FakeProcessRunner prozesse;
    late DateTime jetzt;

    setUp(() {
      prozesse = FakeProcessRunner();
      jetzt = DateTime(2026, 11, 10, 9);
    });

    ArpTabelle tabelle(String os) => ArpTabelle(
      start: prozesse.starter,
      betriebssystem: os,
      clock: () => jetzt,
    );

    test('fragt arp -n bzw. arp -a und merkt sich die Antwort 60 s', () async {
      prozesse.stdoutOf['-n'] = _macos;
      final arp = tabelle('macos');
      expect(await arp.macFuer('192.168.0.50'), '00:26:ab:00:00:01');
      expect(await arp.macFuer('192.168.0.50'), '00:26:ab:00:00:01');
      expect(prozesse.calls, hasLength(1), reason: 'zwischengespeichert');
      expect(prozesse.sawCall('arp', <String>['-n', '192.168.0.50']), isTrue);

      jetzt = jetzt.add(arpZwischenspeicher);
      await arp.macFuer('192.168.0.50');
      expect(prozesse.calls, hasLength(2), reason: 'nach 60 s neu');

      arp.vergiss('192.168.0.50');
      await arp.macFuer('192.168.0.50');
      expect(prozesse.calls, hasLength(3));

      prozesse.stdoutOf['-a'] = _windows;
      expect(await tabelle('windows').macFuer('192.168.0.50'), isNotNull);
      expect(prozesse.sawCall('arp', <String>['-a', '192.168.0.50']), isTrue);
    });

    test('ganze Tabelle mit -an bzw. -a', () async {
      prozesse.stdoutOf['-an'] = _macosTabelle;
      expect(await tabelle('macos').alle(), hasLength(3));
      prozesse.stdoutOf['-a'] = _windows;
      expect(await tabelle('windows').alle(), hasLength(1));
    });

    test('fehlendes oder hängendes arp: unbekannt, ohne zu werfen', () async {
      prozesse.missing.add('arp');
      expect(await tabelle('linux').macFuer('192.168.0.50'), isNull);
      expect(await tabelle('linux').alle(), isEmpty);

      final haengend = FakeProcessRunner()
        ..antwort = (_, _) => Completer<ProcessResult>().future;
      final arp = ArpTabelle(
        start: haengend.starter,
        betriebssystem: 'macos',
        clock: () => jetzt,
      );
      // Der Prozess antwortet nie: dass der Aufruf zurückkehrt, zeigt die
      // Frist – ohne Messung der Wanduhr.
      expect(
        await arp.macFuer(
          '192.168.0.50',
          frist: const Duration(milliseconds: 50),
        ),
        isNull,
      );
      expect(haengend.killed, hasLength(1), reason: 'Prozess beendet');
    });
  });
}
