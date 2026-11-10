import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

void main() {
  group('DLE EOT: feste Bits', () {
    // Epson ESC/POS Command Reference, DLE EOT n: Bit 0 = 0, Bit 1 = 1,
    // Bit 4 = 1, Bit 7 = 0 in jeder Antwort.
    const faelle = <int, bool>{
      0x12: true, // nur die festen Bits
      0x16: true, // + Bit 2 (Deckel offen bei n = 2)
      0x72: true, // + Bit 5, 6 (Papier leer bei n = 4)
      0x1E: true, // + Bit 2, 3 (fast leer bei n = 4)
      0x00: false,
      0x10: false, // ASB-Byte 1: Bit 1 = 0
      0x13: false, // Bit 0 = 1
      0x92: false, // Bit 7 = 1
      0x02: false, // Bit 4 = 0
      0xFF: false,
      0x5F: false, // GS-I-Kopf
      -1: false,
      0x112: false,
    };
    faelle.forEach((byte, gueltig) {
      test('0x${byte.toRadixString(16)} → $gueltig', () {
        expect(istEchtzeitStatus(byte), gueltig);
      });
    });

    test('Befehlsbytes', () {
      expect(dleEot(dleEotOfflineGrund), <int>[0x10, 0x04, 2]);
      expect(dleEot(dleEotRollensensor), <int>[0x10, 0x04, 4]);
      expect(gsI(gsIModell), <int>[0x1D, 0x49, 67]);
      expect(gsI(gsISeriennummer), <int>[0x1D, 0x49, 68]);
    });
  });

  group('GS I: Rahmen', () {
    List<int> rahmen(String text) => <int>[0x5F, ...text.codeUnits, 0x00];

    test('gültiger Rahmen ergibt den Text', () {
      expect(leseGsIRahmen(rahmen('X5ZT000123')), isA<GsIGueltig>());
      expect(
        (leseGsIRahmen(rahmen(' TM-m30III ')) as GsIGueltig).text,
        'TM-m30III',
      );
    });

    test('Bytes vor dem Kopf werden übergangen', () {
      final stand = leseGsIRahmen(<int>[0x12, 0x10, ...rahmen('TM-T20III')]);
      expect((stand as GsIGueltig).text, 'TM-T20III');
    });

    final unvollstaendig = <String, List<int>>{
      'leer': <int>[],
      'ohne Kopf': <int>[0x12, 0x41],
      'ohne Ende': <int>[0x5F, 0x41, 0x42],
    };
    unvollstaendig.forEach((name, bytes) {
      test('unvollständig: $name', () {
        expect(leseGsIRahmen(bytes), isA<GsIUnvollstaendig>());
      });
    });

    final ungueltig = <String, List<int>>{
      'Steuerzeichen': <int>[0x5F, 0x41, 0x07, 0x00],
      'nicht ASCII': <int>[0x5F, 0x41, 0xC3, 0xA4, 0x00],
      'leer': <int>[0x5F, 0x00],
      'nur Leerzeichen': <int>[0x5F, 0x20, 0x20, 0x00],
      'zu lang': <int>[0x5F, ...List<int>.filled(gsIMaxLaenge + 1, 0x41), 0x00],
    };
    ungueltig.forEach((name, bytes) {
      test('ungültig: $name', () {
        expect(leseGsIRahmen(bytes), isA<GsIUngueltig>());
      });
    });

    test('genau die Höchstlänge ist noch gültig', () {
      expect(leseGsIRahmen(rahmen('A' * gsIMaxLaenge)), isA<GsIGueltig>());
    });
  });

  group('Kennungsregeln', () {
    test('MAC-Vergleich', () {
      expect(
        vergleicheMac('00:26:ab:00:00:01', '0:26:AB:0:0:1'),
        MacVergleich.gleich,
      );
      expect(
        vergleicheMac('00:26:ab:00:00:01', '00:26:ab:00:00:02'),
        MacVergleich.anders,
      );
      expect(vergleicheMac(null, '00:26:ab:00:00:02'), MacVergleich.unbekannt);
      expect(vergleicheMac('00:26:ab:00:00:01', null), MacVergleich.unbekannt);
      expect(
        vergleicheMac('00:26:ab:00:00:01', 'kaputt'),
        MacVergleich.unbekannt,
      );
    });

    test('wann GS I 68 gefragt wird', () {
      const serie = 'X5ZT000123';
      final faelle = <(String?, MacVergleich, bool), bool>{
        (null, MacVergleich.anders, false): false,
        (serie, MacVergleich.gleich, false): false,
        (serie, MacVergleich.unbekannt, true): false,
        (serie, MacVergleich.unbekannt, false): true,
        (serie, MacVergleich.anders, true): true,
        (serie, MacVergleich.anders, false): true,
      };
      faelle.forEach((fall, erwartet) {
        expect(
          seriennummerFragen(
            gespeicherteSerie: fall.$1,
            mac: fall.$2,
            frisch: fall.$3,
          ),
          erwartet,
          reason: '$fall',
        );
      });
    });

    test('nur eine andere Seriennummer beweist einen Konflikt', () {
      const serie = 'X5ZT000123';
      final faelle = <(String?, MacVergleich, String?, bool), KennungsLage>{
        (serie, MacVergleich.anders, 'X5ZT000999', false):
            KennungsLage.konflikt,
        (serie, MacVergleich.gleich, 'X5ZT000999', true): KennungsLage.konflikt,
        (serie, MacVergleich.anders, 'x5zt 000123', false):
            KennungsLage.bestaetigt,
        // Andere MAC ohne Antwort: kein Beweis.
        (serie, MacVergleich.anders, null, false): KennungsLage.unbekannt,
        (serie, MacVergleich.anders, null, true): KennungsLage.unbekannt,
        (null, MacVergleich.anders, null, false): KennungsLage.unbekannt,
        (null, MacVergleich.anders, 'X5ZT000999', false):
            KennungsLage.unbekannt,
        (null, MacVergleich.gleich, null, false): KennungsLage.bestaetigt,
        (serie, MacVergleich.unbekannt, null, true): KennungsLage.bestaetigt,
        (serie, MacVergleich.unbekannt, null, false): KennungsLage.unbekannt,
      };
      faelle.forEach((fall, erwartet) {
        expect(
          beurteileKennung(
            gespeicherteSerie: fall.$1,
            mac: fall.$2,
            geseheneSerie: fall.$3,
            frisch: fall.$4,
          ),
          erwartet,
          reason: '$fall',
        );
      });
    });

    test('Abbildung auf die Vertragsnamen', () {
      expect(KennungsLage.values.map((l) => l.wireName), <String>[
        'confirmed',
        'unknown',
        'conflict',
      ]);
    });
  });

  group('ergaenzeKennung', () {
    final jetzt = DateTime.utc(2026, 11, 10, 9);
    PrinterConfig drucker({String? serial, String? mac, String? model}) =>
        PrinterConfig(
          id: 'p1',
          name: 'Bon',
          kind: PrinterKind.tcp9100,
          host: '192.168.0.50',
          serial: serial,
          mac: mac,
          model: model,
          identitySource: serial == null ? null : KennungsQuelle.escpos,
        );

    test('trägt Fehlendes ein und nennt die Quelle der Seriennummer', () {
      final neu = ergaenzeKennung(
        drucker(),
        const ErkannteKennung(
          model: 'TM-m30III',
          modelQuelle: KennungsQuelle.mdns,
          serial: 'X5ZT000123',
          serialQuelle: KennungsQuelle.escpos,
          mac: '0:26:ab:0:0:1',
        ),
        jetzt,
      )!;
      expect(neu.serial, 'X5ZT000123');
      expect(neu.mac, '00:26:ab:00:00:01');
      expect(neu.model, 'TM-m30III');
      expect(neu.identitySource, KennungsQuelle.escpos);
      expect(neu.identifiedAt, jetzt);
    });

    test('nur MAC: Quelle arp; nur Modell: Quelle des Modells', () {
      expect(
        ergaenzeKennung(
          drucker(),
          const ErkannteKennung(mac: '00:26:ab:00:00:01'),
          jetzt,
        )!.identitySource,
        KennungsQuelle.arp,
      );
      final nurModell = ergaenzeKennung(
        drucker(),
        const ErkannteKennung(
          model: 'TM-m30III',
          modelQuelle: KennungsQuelle.mdns,
        ),
        jetzt,
      )!;
      expect(nurModell.identitySource, KennungsQuelle.mdns);
      expect(nurModell.hatKennung, isFalse);
    });

    test('überschreibt nie eine vorhandene Kennung', () {
      final vorher = drucker(serial: 'X5ZT000123', mac: '00:26:ab:00:00:01');
      final neu = ergaenzeKennung(
        vorher,
        const ErkannteKennung(
          serial: 'X5ZT000999',
          serialQuelle: KennungsQuelle.escpos,
          mac: '00:26:ab:00:00:09',
          model: 'TM-T20III',
        ),
        jetzt,
      )!;
      expect(neu.serial, 'X5ZT000123');
      expect(neu.mac, '00:26:ab:00:00:01');
      expect(neu.model, 'TM-T20III', reason: 'das Modell fehlte');
      expect(neu.identitySource, KennungsQuelle.escpos);
    });

    test('nichts Neues: null', () {
      expect(ergaenzeKennung(drucker(), ErkannteKennung.keine, jetzt), isNull);
    });
  });

  group('kennungAusTxt', () {
    test('usb_MDL vor product vor ty, Seriennummer nur ausdrücklich', () {
      final k = kennungAusTxt(
        'txtvers=1\nty=EPSON TM-m30III\nproduct=(TM-m30III)\n'
        'usb_MDL=TM-m30III\nserialNumber=X5ZT000123\n',
      );
      expect(k.model, 'TM-m30III');
      expect(k.modelQuelle, KennungsQuelle.mdns);
      expect(k.serial, 'X5ZT000123');
      expect(k.serialQuelle, KennungsQuelle.mdns);
    });

    test('product ohne Klammern, sonst ty', () {
      expect(kennungAusTxt('product=(TM-T20III)\n').model, 'TM-T20III');
      expect(kennungAusTxt('ty=EPSON TM-T88VI\n').model, 'EPSON TM-T88VI');
      expect(kennungAusTxt('note=Kasse\n').leer, isTrue);
    });

    test('Unsinn und Steuerzeichen zählen nicht', () {
      final k = kennungAusTxt('usb_MDL=\nsn=\u0007x\n=leer\nkeingleich\n');
      expect(k.model, isNull);
      expect(k.serial, isNull);
    });
  });
}
