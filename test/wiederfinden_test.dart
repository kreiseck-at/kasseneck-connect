import 'dart:async';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_epos.dart';
import 'support/fake_printer.dart';
import 'support/virtuelles_netz.dart';

const String _serie = 'X5ZT000123';
const String _mac = '00:26:ab:00:00:01';
const String _alt = '192.168.0.50';
const String _neu = '192.168.0.61';
const Map<int, int> _gesund = <int, int>{2: 0x12, 4: 0x12};

PrinterConfig _drucker({String? serial = _serie, String? mac = _mac}) =>
    PrinterConfig(
      id: 'p_ab12cd34',
      name: 'Bon',
      kind: PrinterKind.tcp9100,
      host: _alt,
      serial: serial,
      mac: mac,
    );

void main() {
  group('Kandidatenwahl (rein)', () {
    test('mit Seriennummer zählt nur dieselbe Seriennummer', () {
      final d = _drucker();
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(host: _neu, port: 9100, serie: 'x5zt000123'),
        ),
        isTrue,
      );
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(host: _neu, port: 9100, mac: _mac),
        ),
        isFalse,
        reason: 'MAC allein reicht bei gespeicherter Seriennummer nicht',
      );
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(host: _neu, port: 9100, serie: 'X5ZT000999'),
        ),
        isFalse,
      );
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(host: _alt, port: 9100, serie: _serie),
        ),
        isFalse,
        reason: 'die alte Adresse ist kein Fund',
      );
    });

    test('nur mit MAC: dieselbe MAC und ein Protokollbeweis', () {
      final d = _drucker(serial: null);
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(
            host: _neu,
            port: 9100,
            mac: '0:26:ab:0:0:1',
            sprichtProtokoll: true,
          ),
        ),
        isTrue,
      );
      // Offener Port mit derselben MAC (Weboberfläche eines Repeaters mit
      // MAC-NAT) ist kein Beweis.
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(host: _neu, port: 9100, mac: '0:26:ab:0:0:1'),
        ),
        isFalse,
      );
      expect(
        kandidatBestaetigt(
          d,
          const DruckerKandidat(host: _neu, port: 9100, sprichtProtokoll: true),
        ),
        isFalse,
      );
    });

    test('genau einer, sonst keiner', () {
      final d = _drucker();
      const eins = DruckerKandidat(host: _neu, port: 9100, serie: _serie);
      const zwei = DruckerKandidat(
        host: '192.168.0.62',
        port: 9100,
        serie: _serie,
      );
      const fremd = DruckerKandidat(
        host: '192.168.0.63',
        port: 9100,
        serie: 'Y',
      );
      expect(einzigerKandidat(d, <DruckerKandidat>[eins, fremd]), same(eins));
      expect(einzigerKandidat(d, <DruckerKandidat>[eins, eins]), same(eins));
      expect(einzigerKandidat(d, <DruckerKandidat>[eins, zwei]), isNull);
      expect(einzigerKandidat(d, const <DruckerKandidat>[]), isNull);
    });
  });

  group('über die Warteschlange', () {
    late VirtuellesNetz netz;
    late DruckAufbau a;
    late FakeTcpPrinter drucker;
    final ereignisse = <AgentEvent>[];
    late StreamSubscription<AgentEvent> abo;

    setUp(() async {
      netz = VirtuellesNetz();
      a = DruckAufbau.erstellen(netz: netz);
      drucker = await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: _serie},
      );
      ereignisse.clear();
      abo = a.events.stream.listen(ereignisse.add);
      // Der Drucker ist umgezogen: unter der alten Adresse nichts mehr, der
      // veraltete ARP-Eintrag bleibt stehen.
      netz
        ..macs[_alt] = _mac
        ..stelle(_neu, 9100, drucker.port, mac: _mac);
    });

    tearDown(() async {
      await abo.cancel();
      await drucker.stop();
      await a.aufraeumen();
    });

    Future<PrintResult> drucke(String id) async {
      final vorher = drucker.druckVerbindungen.length;
      final ergebnis = await a.drucke(id);
      if (ergebnis.ok) await drucker.warteAufDruck(vorher);
      return ergebnis;
    }

    Future<PrinterConfig> gespeichert([String id = 'p_ab12cd34']) async =>
        (await a.store.load()).printers.singleWhere((d) => d.id == id);

    test('keine Verbindung vor dem ersten Byte: per ARP gefunden, der Bon geht '
        'an die neue Adresse, still', () async {
      final id = await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);
      final ergebnis = await drucke(id);
      expect(ergebnis.ok, isTrue, reason: 'die Kasse merkt nichts');
      expect(drucker.druckVerbindungen.single, beispielBon);
      expect((await gespeichert()).host, _neu);

      final config = await a.store.load();
      final wechsel = config.relocations.single;
      expect(wechsel.art, GeraeteArt.drucker);
      expect(wechsel.von, '$_alt:9100');
      expect(wechsel.nach, '$_neu:9100');
      expect(
        a.logZeilen.where(
          (z) => z.contains('Adresse $_alt → $_neu, Kennung bestätigt'),
        ),
        hasLength(1),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        ereignisse.where((e) => e.type == eventPrinterRelocated).single.data,
        <String, Object?>{
          'printerId': id,
          'from': '$_alt:9100',
          'to': '$_neu:9100',
        },
      );
      expect(a.wiederfinder.suchen, 1);
    });

    test('zwei Geräte mit derselben Kennung: keins übernommen', () async {
      final zweiter = await FakeTcpPrinter.start(
        dleEot: _gesund,
        gsI: const <int, String>{68: _serie},
      );
      addTearDown(zweiter.stop);
      netz.stelle('192.168.0.62', 9100, zweiter.port, mac: _mac);
      final id = await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);
      final ergebnis = await a.drucke(id);
      expect(ergebnis.code, errorPrinterOffline, reason: 'wie 1.4.2');
      expect((await gespeichert()).host, _alt);
      // Dieselbe MAC unter zwei neuen Adressen ist keine Kennung …
      expect(
        a.logZeilen.where((z) => z.contains('steht unter 2 Adressen')),
        isNotEmpty,
      );
      // … und dieselbe Seriennummer an zwei Geräten auch nicht.
      expect(await a.wiederfinder.gruendlich(id, erzwingen: true), isNull);
      expect((await gespeichert()).host, _alt);
      expect(
        a.logZeilen.where((z) => z.contains('Geräte mit derselben Kennung')),
        isNotEmpty,
      );
    });

    test('anderes Gerät mit derselben MAC, aber anderer Seriennummer: nicht '
        'übernommen', () async {
      drucker.gsI[68] = 'X5ZT000999';
      final id = await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);
      expect((await a.drucke(id)).code, errorPrinterOffline);
      expect((await gespeichert()).host, _alt);
    });

    test('mDNS-TXT mit Seriennummer findet ihn ohne MAC', () async {
      netz.macs.clear();
      a.mdnsFunde = <DiscoveredPrinter>[
        const DiscoveredPrinter(
          host: _neu,
          port: 9100,
          kind: PrinterKind.tcp9100,
          serial: _serie,
        ),
      ];
      final id = await a.drucker(9100, host: _alt, serial: _serie);
      expect((await drucke(id)).ok, isTrue);
      expect((await gespeichert()).host, _neu);
    });

    test('mDNS nennt nur das Modell: per GS I bestätigt übernommen', () async {
      netz.macs.clear();
      a.mdnsFunde = <DiscoveredPrinter>[
        const DiscoveredPrinter(
          host: _neu,
          port: 9100,
          kind: PrinterKind.tcp9100,
          model: 'TM-T20III',
        ),
      ];
      await a.store.mutate(
        (c) => c.copyWith(
          printers: <PrinterConfig>[
            PrinterConfig(
              id: 'p_ab12cd34',
              name: 'Bon',
              kind: PrinterKind.tcp9100,
              host: _alt,
              model: 'TM-T20III',
              serial: _serie,
            ),
          ],
        ),
      );
      final neu = await a.wiederfinder.schnell(await gespeichert());
      expect(neu?.host, _neu);
    });

    test('mit MAC nur die ARP-Tabelle: kein mDNS, kein Warten', () async {
      netz.macs.remove(_neu);
      var mdns = 0;
      final wf = DruckerWiederfinder(
        registry: a.registry,
        arp: a.arp,
        abfrage: EscPosAbfrage(verbinden: netz.verbinden),
        suche: PrinterDiscovery(
          mdns: (_) async {
            mdns++;
            return const <DiscoveredPrinter>[];
          },
        ),
        schnittstellen: () async => a.schnittstellen,
        clock: () => a.jetzt,
      );
      addTearDown(wf.beenden);
      await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);
      expect(await wf.schnell(await gespeichert()), isNull);
      expect(mdns, 0);
    });

    test('schnelles Wiederfinden höchstens einmal je Minute', () async {
      netz.macs.remove(_neu);
      final id = await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);
      await a.wiederfinder.schnell(await gespeichert(id));
      await a.wiederfinder.schnell(await gespeichert(id));
      expect(a.wiederfinder.suchen, 1);
      a.jetzt = a.jetzt.add(schnellAbstand);
      await a.wiederfinder.schnell(await gespeichert(id));
      expect(a.wiederfinder.suchen, 2);
    });

    group('nie eine falsche Adresse', () {
      const repeater = '00:11:22:33:44:55';

      test('nur MAC: ein offener Druckport ohne Antwort auf DLE EOT ist kein '
          'Beweis', () async {
        final fremd = await FakeTcpPrinter.start();
        addTearDown(fremd.stop);
        netz.stelle('192.168.0.70', 9100, fremd.port, mac: _mac);
        netz.entferne(_neu);
        netz.macs.remove(_neu);
        final id = await a.drucker(9100, host: _alt, mac: _mac);
        expect(await a.wiederfinder.schnell(await gespeichert(id)), isNull);
        expect(await a.wiederfinder.gruendlich(id, erzwingen: true), isNull);
        expect((await gespeichert(id)).host, _alt);
        expect(fremd.druckVerbindungen, isEmpty);
      });

      test('nur MAC: mit gültiger Antwort auf DLE EOT übernommen', () async {
        final id = await a.drucker(9100, host: _alt, mac: _mac);
        expect(
          (await a.wiederfinder.schnell(await gespeichert(id)))?.host,
          _neu,
        );
      });

      test('Repeater mit MAC-NAT: dieselbe MAC unter einem anderen '
          'eingerichteten Drucker wird nie übernommen', () async {
        final kueche = await FakeTcpPrinter.start(dleEot: _gesund);
        addTearDown(kueche.stop);
        netz
          ..macs.clear()
          ..macs[_alt] = repeater
          ..entferne(_neu)
          ..stelle('192.168.0.62', 9100, kueche.port, mac: repeater);
        await a.drucker(9100, host: '192.168.0.62', id: 'p_kueche');
        await a.drucker(9100, host: _alt, mac: repeater);
        expect(
          await a.wiederfinder.gruendlich('p_ab12cd34', erzwingen: true),
          isNull,
        );
        expect(
          await a.wiederfinder.schnell(await gespeichert('p_ab12cd34')),
          isNull,
        );
        expect((await gespeichert('p_ab12cd34')).host, _alt);
        expect((await gespeichert('p_kueche')).host, '192.168.0.62');
      });

      test('Repeater mit MAC-NAT: dieselbe MAC unter mehreren fremden Adressen '
          'ist keine Kennung – auch wenn nur eine davon antwortet', () async {
        // Unter _neu steht der Repeater selbst (kein Druckport), unter .62
        // ein Drucker hinter ihm – ob es der eingerichtete ist, sagt die MAC
        // nicht.
        final zweiter = await FakeTcpPrinter.start(dleEot: _gesund);
        addTearDown(zweiter.stop);
        netz
          ..entferne(_neu)
          ..macs[_neu] = repeater
          ..macs[_alt] = repeater
          ..stelle('192.168.0.62', 9100, zweiter.port, mac: repeater);
        final id = await a.drucker(9100, host: _alt, mac: repeater);
        expect(await a.wiederfinder.schnell(await gespeichert(id)), isNull);
        expect(await a.wiederfinder.gruendlich(id, erzwingen: true), isNull);
        expect((await gespeichert(id)).host, _alt);
      });

      test('Nachbau mit fester Seriennummer: trägt ein anderer eingerichteter '
          'Drucker dieselbe, wird nichts übernommen', () async {
        final kueche = await FakeTcpPrinter.start(
          dleEot: _gesund,
          gsI: const <int, String>{68: _serie},
        );
        addTearDown(kueche.stop);
        netz.stelle('192.168.0.62', 9100, kueche.port);
        await a.drucker(
          9100,
          host: '192.168.0.62',
          id: 'p_kueche',
          serial: _serie,
        );
        await a.drucker(9100, host: _alt, serial: _serie);
        // Unter _neu antwortet ebenfalls _serie – auch das zählt nicht.
        expect(
          await a.wiederfinder.gruendlich('p_ab12cd34', erzwingen: true),
          isNull,
        );
        expect((await gespeichert('p_ab12cd34')).host, _alt);
        expect((await gespeichert('p_kueche')).host, '192.168.0.62');
        expect(
          a.logZeilen.where((z) => z.contains('dieselbe Kennung')),
          isNotEmpty,
        );
      });

      test('mDNS nennt unter der Adresse eines anderen Druckers eine '
          'Seriennummer: zählt nicht (nur GS I zählt dort)', () async {
        netz.macs.clear();
        netz.entferne(_neu);
        final kueche = await FakeTcpPrinter.start(
          dleEot: _gesund,
          gsI: const <int, String>{68: 'X5ZT000777'},
        );
        addTearDown(kueche.stop);
        netz.stelle('192.168.0.62', 9100, kueche.port);
        await a.drucker(
          9100,
          host: '192.168.0.62',
          id: 'p_kueche',
          serial: 'X5ZT000777',
        );
        a.mdnsFunde = <DiscoveredPrinter>[
          const DiscoveredPrinter(
            host: '192.168.0.62',
            port: 9100,
            kind: PrinterKind.tcp9100,
            serial: _serie,
          ),
        ];
        await a.drucker(9100, host: _alt, serial: _serie);
        expect(
          await a.wiederfinder.schnell(await gespeichert('p_ab12cd34')),
          isNull,
        );
      });

      group('ePOS', () {
        late FakeEposServer epos;
        late HttpServer web;

        setUp(() async {
          epos = await FakeEposServer.start(status: '2');
          // Weboberfläche eines Repeaters: Port 80 offen, aber kein ePOS.
          web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          web.listen((anfrage) {
            anfrage.response
              ..statusCode = 200
              ..write('<html><body>Repeater</body></html>');
            unawaited(anfrage.response.close());
          });
          netz.macs.clear();
        });

        tearDown(() async {
          await epos.stop();
          await web.close(force: true);
        });

        Future<PrinterConfig> eposDrucker() async {
          await a.store.mutate(
            (c) => c.copyWith(
              printers: <PrinterConfig>[
                PrinterConfig(
                  id: 'p_epos',
                  name: 'Bon',
                  kind: PrinterKind.epos,
                  host: _alt,
                  port: 80,
                  mac: repeater,
                ),
              ],
            ),
          );
          return gespeichert('p_epos');
        }

        test(
          'hinter der Weboberfläche eines Repeaters: nicht übernommen',
          () async {
            netz
              ..macs[_alt] = repeater
              ..stelle('192.168.0.2', 80, web.port, mac: repeater);
            expect(await a.wiederfinder.schnell(await eposDrucker()), isNull);
            // Auch ohne den veralteten Eintrag: offener Port ohne ePOS-Antwort.
            netz.macs.remove(_alt);
            a.jetzt = a.jetzt.add(schnellAbstand);
            expect(await a.wiederfinder.schnell(await eposDrucker()), isNull);
            expect((await gespeichert('p_epos')).host, _alt);
          },
        );

        test('mit gültiger ePOS-Antwort übernommen', () async {
          netz.stelle(_neu, 80, epos.port, mac: repeater);
          final neu = await a.wiederfinder.schnell(await eposDrucker());
          expect(neu?.host, _neu);
          expect(epos.lastCommand, isNull, reason: 'kein Bon, nur Status');
        });
      });
    });

    test('printer_relocate aus: keine Suche, Fehler wie 1.4.2', () async {
      await a.abschalten(<Neuerung>[Neuerung.druckerWiederfinden]);
      final id = await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);
      expect((await a.drucke(id)).code, errorPrinterOffline);
      expect(a.wiederfinder.suchen, 0);
      expect((await gespeichert()).host, _alt);
    });

    test('ohne Kennung: keine Suche', () async {
      final id = await a.drucker(9100, host: _alt);
      expect((await a.drucke(id)).code, errorPrinterOffline);
      expect(a.wiederfinder.suchen, 0);
    });

    group('gründlich', () {
      setUp(() {
        // ARP kennt den neuen Ort erst nach dem Scan nicht – Netzscan nötig.
        netz.macs.remove(_neu);
      });

      test('Netzscan und GS I finden ihn; höchstens einmal in zwei Minuten, '
          'locate erzwingt', () async {
        final id = await a.drucker(9100, host: _alt, serial: _serie);
        expect((await a.wiederfinder.gruendlich(id))?.host, _neu);
        expect((await gespeichert()).host, _neu);

        // Zurück an die alte Adresse gestellt, wieder umgezogen: binnen zwei
        // Minuten keine zweite Suche, erzwungen schon.
        await a.store.mutate(
          (c) => c.copyWith(
            printers: <PrinterConfig>[c.printers.single.copyWith(host: _alt)],
          ),
        );
        expect(await a.wiederfinder.gruendlich(id), isNull);
        expect(
          (await a.wiederfinder.gruendlich(id, erzwingen: true))?.host,
          _neu,
        );
        a.jetzt = a.jetzt.add(gruendlichAbstand);
        await a.store.mutate(
          (c) => c.copyWith(
            printers: <PrinterConfig>[c.printers.single.copyWith(host: _alt)],
          ),
        );
        expect((await a.wiederfinder.gruendlich(id))?.host, _neu);
      });

      test('nie während einer Zahlung', () async {
        final id = await a.drucker(9100, host: _alt, serial: _serie);
        a.zahlung = true;
        expect(await a.wiederfinder.gruendlich(id, erzwingen: true), isNull);
        expect(a.wiederfinder.suchen, 0);
        expect(netz.versuche[_neu], isNull, reason: 'kein Scan');
      });

      test('gleichzeitige Auslöser: genau eine Suche, alle bekommen dasselbe '
          'Ergebnis, ein Adresswechsel', () async {
        final id = await a.drucker(9100, host: _alt, serial: _serie);
        final ergebnisse = await Future.wait(<Future<PrinterConfig?>>[
          a.wiederfinder.gruendlich(id),
          a.wiederfinder.gruendlich(id, erzwingen: true),
          a.wiederfinder.gruendlich(id),
        ]);
        expect(ergebnisse.map((d) => d?.host), <String?>[_neu, _neu, _neu]);
        expect(a.wiederfinder.suchen, 1);
        expect((await a.store.load()).relocations, hasLength(1));
      });

      test(
        'ein paralleles Koppeln geht beim Adresswechsel nicht verloren',
        () async {
          final id = await a.drucker(9100, host: _alt, serial: _serie);
          await Future.wait(<Future<Object?>>[
            a.wiederfinder.gruendlich(id),
            for (var i = 0; i < 5; i++)
              a.store.mutate(
                (c) =>
                    c.copyWith(tokenHashes: <String>[...c.tokenHashes, 't$i']),
              ),
          ]);
          final config = await a.store.load();
          expect(config.printers.single.host, _neu);
          expect(config.tokenHashes, hasLength(5));
        },
      );

      test('Kandidat unter der Adresse eines anderen Druckers: die gründliche '
          'Suche fragt erst, wenn dessen Warteschlange frei ist; die schnelle '
          'lässt ihn aus', () async {
        final anderer = await FakeTcpPrinter.start(
          dleEot: _gesund,
          gsI: const <int, String>{68: 'X5ZT000777'},
        );
        addTearDown(anderer.stop);
        netz.stelle('192.168.0.62', 9100, anderer.port, mac: _mac);
        await a.drucker(
          9100,
          host: '192.168.0.62',
          id: 'p_anderer',
          serial: 'X5ZT000777',
        );
        final id = await a.drucker(9100, host: _alt, serial: _serie, mac: _mac);

        // Schnell (im Auftrag): der andere Drucker wird nicht gefragt.
        netz.entferne(_neu);
        expect(await a.wiederfinder.schnell((await gespeichert(id))), isNull);
        expect(anderer.connections, 0);

        // Gründlich: wartet, solange der andere Drucker druckt.
        final halten = Completer<void>();
        final bon = a.queue.exclusive('p_anderer', () => halten.future);
        final suche = a.wiederfinder.gruendlich(id, erzwingen: true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(anderer.connections, 0, reason: 'nie neben seinem Bon');
        halten.complete();
        await bon;
        expect(await suche, isNull, reason: 'andere Seriennummer');
        expect(anderer.connections, 1);
        expect(anderer.hoechstGleichzeitig, 1);
      });

      test('Statustakt: nach zwei Fehlversuchen gründliche Suche', () async {
        final id = await a.drucker(9100, host: _alt, serial: _serie);
        final dienst = DruckerStatusDienst(
          registry: a.registry,
          queue: a.queue,
          abfrage: EscPosAbfrage(verbinden: netz.verbinden),
          kasseZuletzt: () => a.jetzt,
          clock: () => a.jetzt,
        )..beiDauerndVerfehlt = a.wiederfinder.gruendlichImHintergrund;
        await dienst.runde();
        await dienst.runde();
        await warteAufAdresse(a, id, _neu);
      });
    });
  });
}

Future<void> warteAufAdresse(DruckAufbau a, String id, String host) async {
  final ende = DateTime.now().add(const Duration(seconds: 15));
  while ((await a.store.load()).printers.singleWhere((d) => d.id == id).host !=
      host) {
    if (DateTime.now().isAfter(ende)) fail('$id nicht nach $host umgezogen');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
