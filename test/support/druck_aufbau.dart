import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;

import 'fake_process_runner.dart';
import 'virtuelles_netz.dart';

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

  /// Mit [netz] laufen alle Verbindungen, Proben und ARP-Ausgaben über das
  /// virtuelle Kassen-Netz statt über Loopback.
  ///
  /// [budget] ersetzt das Zeitbudget der Vorprüfung (Tests, deren Antworten
  /// über HTTP kommen und unter Last länger brauchen dürfen).
  ///
  /// [verbinden] ersetzt den Verbindungsaufbau zu den Geräten (etwa
  /// `FakeTcpPrinter.verbinden`), auch den des [netz].
  static DruckAufbau erstellen({
    DateTime? start,
    VirtuellesNetz? netz,
    Duration budget = vorpruefungBudget,
    SocketConnector? verbinden,
  }) {
    final temp = Directory.systemTemp.createTempSync('connect-druck-');
    final aufbau = DruckAufbau._(
      temp,
      ConfigStore.forDirectory(temp),
      AgentLog(Directory(p.join(temp.path, 'logs'))),
      FakeProcessRunner(),
    );
    aufbau
      ..netz = netz
      .._verbinden = verbinden
      .._budget = budget
      ..jetzt = start ?? DateTime(2026, 11, 10, 9);
    if (netz != null) {
      aufbau.schnittstellen = const <LocalInterface>[VirtuellesNetz.eigene];
      aufbau.prozesse.antwort = (programm, argumente) async {
        if (programm != 'arp') return null;
        final ausgabe = argumente.first == '-an'
            ? netz.arpTabelle()
            : netz.arpEinzeln(argumente.last);
        return ProcessResult(1, 0, ausgabe, '');
      };
    }
    aufbau._bauen();
    return aufbau;
  }

  Duration _budget = vorpruefungBudget;
  SocketConnector? _verbinden;

  /// Das virtuelle Netz, falls eines verwendet wird.
  VirtuellesNetz? netz;

  /// Funde der mDNS-Suche (für das Wiederfinden).
  List<DiscoveredPrinter> mdnsFunde = const <DiscoveredPrinter>[];

  /// Ob gerade eine Zahlung läuft (für das Wiederfinden).
  bool zahlung = false;

  late final DruckerWiederfinder wiederfinder;

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
    final verbinden = _verbinden ?? netz?.verbinden;
    registry = PrinterRegistry(
      store: store,
      log: log,
      events: events,
      verbinden: verbinden,
      eposVerbinden: netz?.httpVerbinden,
    );
    queue = PrintQueue(
      registry: registry,
      events: events,
      log: log,
      clock: () => jetzt,
    );
    final abfrage = EscPosAbfrage(verbinden: verbinden);
    wiederfinder = DruckerWiederfinder(
      registry: registry,
      arp: arp,
      abfrage: abfrage,
      suche: PrinterDiscovery(mdns: (_) async => mdnsFunde),
      schnittstellen: () async => schnittstellen,
      queue: queue,
      events: events,
      tcp: netz?.tcp ?? tcpReachable,
      zahlungLaeuft: () => zahlung,
      log: log,
      clock: () => jetzt,
    );
    vorpruefung = DruckVorpruefung(
      registry: registry,
      abfrage: abfrage,
      arp: arp,
      schnittstellen: () async => schnittstellen,
      log: log,
      clock: () => jetzt,
      schnellesWiederfinden: wiederfinder.schnell,
      budget: _budget,
    );
    queue
      ..vorpruefung = vorpruefung
      ..wiederfinder = wiederfinder;
  }

  /// Die MAC, die `arp` für 127.0.0.1 meldet (`null`: kein Eintrag).
  set arpMac(String? mac) {
    prozesse.stdoutOf['-n'] = mac == null
        ? '127.0.0.1 (127.0.0.1) -- no entry\n'
        : arpZeile(mac);
    arp.vergiss('127.0.0.1');
  }

  /// Legt einen Drucker unter [host] (Vorgabe Loopback) auf [port] an.
  Future<String> drucker(
    int port, {
    String? serial,
    String? mac,
    String id = 'p_ab12cd34',
    String host = '127.0.0.1',
    DateTime? statusCapableAt,
  }) async {
    await store.mutate(
      (c) => c.copyWith(
        printers: <PrinterConfig>[
          ...c.printers.where((d) => d.id != id),
          PrinterConfig(
            id: id,
            name: 'Bon',
            kind: PrinterKind.tcp9100,
            host: host,
            port: port,
            serial: serial,
            mac: mac,
            statusCapableAt: statusCapableAt,
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
    // Eine Suche oder ein Schreibvorgang im Hintergrund schriebe sonst noch in
    // den Ordner.
    await wiederfinder.beenden();
    await registry.hintergrundErledigt();
    await events.close();
    temp.deleteSync(recursive: true);
  }
}
