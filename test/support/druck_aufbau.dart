import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;

import 'fake_process_runner.dart';

/// Ein Bon, wie ihn die Kasse schickt (ESC @, Text, Schnitt).
final Uint8List beispielBon = Uint8List.fromList(<int>[
  0x1B, 0x40, //
  ...'Bäckerei Kornblum'.codeUnits.map((c) => c & 0xFF),
  0x0A, 0x1D, 0x56, 0x01,
]);

/// `arp -n 127.0.0.1` am Mac mit der MAC [mac].
String arpZeile(String mac) =>
    '? (127.0.0.1) at $mac on lo0 ifscope [ethernet]\n';

/// Registry, Warteschlange und Vorprüfung wie im Agenten, aber mit Uhr,
/// Fake-ARP und Loopback als eigenem Netz.
class DruckAufbau {
  DruckAufbau._(this.temp, this.store, this.log, this.prozesse);

  static DruckAufbau erstellen({DateTime? start}) {
    final temp = Directory.systemTemp.createTempSync('connect-druck-');
    final aufbau = DruckAufbau._(
      temp,
      ConfigStore.forDirectory(temp),
      AgentLog(Directory(p.join(temp.path, 'logs'))),
      FakeProcessRunner(),
    );
    aufbau.jetzt = start ?? DateTime(2026, 11, 10, 9);
    aufbau._bauen();
    return aufbau;
  }

  final Directory temp;
  final ConfigStore store;
  final AgentLog log;
  final FakeProcessRunner prozesse;
  late DateTime jetzt;
  final EventBus events = EventBus();
  late final ArpTabelle arp;
  late final PrinterRegistry registry;
  late final PrintQueue queue;
  late final DruckVorpruefung vorpruefung;

  /// Eigene Schnittstellen; Vorgabe: Loopback als Netz der Drucker.
  List<LocalInterface> schnittstellen = const <LocalInterface>[
    LocalInterface(name: 'lo0', address: '127.0.0.2'),
  ];

  /// Wie oft das schnelle Wiederfinden gefragt wurde.
  int wiederfindenAufrufe = 0;

  void _bauen() {
    arp = ArpTabelle(
      start: prozesse.starter,
      betriebssystem: 'macos',
      log: log,
      clock: () => jetzt,
    );
    registry = PrinterRegistry(store: store, log: log, events: events);
    queue = PrintQueue(registry: registry, events: events, log: log);
    vorpruefung = DruckVorpruefung(
      registry: registry,
      abfrage: EscPosAbfrage(),
      arp: arp,
      schnittstellen: () async => schnittstellen,
      log: log,
      clock: () => jetzt,
    );
    queue.vorpruefung = vorpruefung;
  }

  /// Die MAC, die `arp` für 127.0.0.1 meldet (`null`: kein Eintrag).
  set arpMac(String? mac) {
    prozesse.stdoutOf['-n'] = mac == null
        ? '127.0.0.1 (127.0.0.1) -- no entry\n'
        : arpZeile(mac);
    arp.vergiss('127.0.0.1');
  }

  /// Legt einen Drucker auf [port] an.
  Future<String> drucker(
    int port, {
    String? serial,
    String? mac,
    String id = 'p_ab12cd34',
  }) async {
    await store.mutate(
      (c) => c.copyWith(
        printers: <PrinterConfig>[
          ...c.printers.where((d) => d.id != id),
          PrinterConfig(
            id: id,
            name: 'Bon',
            kind: PrinterKind.tcp9100,
            host: '127.0.0.1',
            port: port,
            serial: serial,
            mac: mac,
          ),
        ],
      ),
    );
    return id;
  }

  /// Druckt [bytes] (Vorgabe [beispielBon]) mit einer frischen Auftrags-ID.
  Future<PrintResult> drucke(String id, {Uint8List? bytes}) =>
      queue.enqueue(id, 'job-${_nummer++}', bytes ?? beispielBon);
  int _nummer = 1;

  /// Schaltet Neuerungen ab.
  Future<void> abschalten(List<Neuerung> neuerungen) => store.mutate(
    (c) => c.copyWith(
      disabledFeatures: neuerungen.map((n) => n.wireName).toList(),
    ),
  );

  /// Logzeilen bis jetzt.
  List<String> get logZeilen =>
      log.file.existsSync() ? log.file.readAsLinesSync() : const <String>[];

  /// Aufrufe von `arp`.
  int get arpAufrufe =>
      prozesse.calls.where((c) => c.executable == 'arp').length;

  Future<void> aufraeumen() async {
    await events.close();
    temp.deleteSync(recursive: true);
  }
}
