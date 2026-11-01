import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kasseneck_connect/src/bluetooth/helper.dart';
import 'package:kasseneck_connect/src/bluetooth/protocol.dart';
import 'package:kasseneck_connect/src/bluetooth/uuids.dart';
import 'package:kasseneck_connect/src/log/logger.dart';

/// Kennung des ersten nachgespielten M110 (erfunden, aus den Protokollbeispielen).
const String fakeM110Id = '3f2a9c1e-7b4d-4e2a-9a10-5c6d7e8f9a0b';

final String _ff00 = canonicalUuid('ff00');
final String _ff02 = canonicalUuid('ff02');
final String _ff03 = canonicalUuid('ff03');

/// Ein Kindprozess im Speicher, wie `Process.start` ihn liefert.
///
/// Was der Agent auf stdin schreibt, steht in [zeilen] und geht an [onZeile];
/// was die Attrappe mit [sendeZeile] schickt, liest der Agent von stdout.
/// **Kein Test startet ein echtes Programm.**
class FakeHelperProcess implements Process {
  FakeHelperProcess(this.pid) {
    _stdin.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (zeile) {
            if (beendet) return;
            zeilen.add(zeile);
            onZeile?.call(zeile);
          },
          onDone: () {
            stdinGeschlossen = true;
            if (!beendet) onStdinEnde?.call();
          },
        );
  }

  @override
  final int pid;

  final StreamController<List<int>> _stdin = StreamController<List<int>>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  late final IOSink _stdinSink = IOSink(_stdin);

  /// Alle Zeilen, die der Agent auf stdin geschrieben hat.
  final List<String> zeilen = <String>[];

  /// Wird für jede neue Zeile auf stdin gerufen.
  void Function(String zeile)? onZeile;

  /// Wird gerufen, wenn der Agent stdin schließt (das Hilfsprogramm endet dann).
  void Function()? onStdinEnde;

  /// Wird gerufen, sobald der Prozess endet (auch durch [kill]).
  void Function()? onEnde;

  /// Ob der Agent stdin geschlossen hat.
  bool stdinGeschlossen = false;

  /// Das Signal, mit dem der Agent den Prozess beendet hat.
  ProcessSignal? killedWith;

  bool get beendet => _exit.isCompleted;

  /// Die Zeilen auf stdin als Befehle (Unlesbares fehlt).
  List<HelperRequest> get befehle =>
      zeilen.map(decodeHelperLine).whereType<HelperRequest>().toList();

  @override
  IOSink get stdin => _stdinSink;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  /// Schreibt eine Zeile auf stdout.
  void sendeZeile(String zeile) => sendeBytes(utf8.encode('$zeile\n'));

  /// Schreibt eine Nachricht des Protokolls auf stdout.
  void sende(HelperMessage nachricht) => sendeZeile(nachricht.encode());

  /// Schreibt rohe Bytes auf stdout (auch halbe Zeilen oder kein UTF-8).
  void sendeBytes(List<int> bytes) {
    if (!beendet) _stdout.add(bytes);
  }

  /// Schreibt eine Notiz auf stderr.
  void notiz(String text) {
    if (!beendet) _stderr.add(utf8.encode('$text\n'));
  }

  /// Beendet den Prozess: stdout und stderr gehen zu, dann der Exitcode.
  void beenden([int code = 0]) {
    if (beendet) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(code);
    onEnde?.call();
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (beendet) return false;
    killedWith = signal;
    beenden(-signal.signalNumber);
    return true;
  }
}

/// Attrappe des Bluetooth-Hilfsprogramms mit dem echten Aufpasser davor.
///
/// Gespielt wird das Programm (`kasseneck-bluetooth`) auf Zeilenebene, so wie
/// `docs/bluetooth-protokoll.md` es beschreibt: `connected` kommt vor der
/// Antwort auf `connect`, ein zweites `connect` meldet `connected` erneut,
/// Befehle warten, solange der Zustand `unknown`/`resetting` ist. Gestartet,
/// überwacht und neu gestartet wird es vom echten [ProcessBluetoothHelper] –
/// Absturz, Hänger und kaputte Zeilen laufen also durch dieselbe Überwachung
/// wie im Betrieb.
class FakeBluetoothHelper implements BluetoothHelper {
  FakeBluetoothHelper({
    required AgentLog log,
    Iterable<FakeM110> geraete = const <FakeM110>[],
    String zustand = 'poweredOn',
    String? zustandBeimNaechstenStart,
    Duration heartbeat = const Duration(seconds: 5),
    Duration callTimeout = const Duration(seconds: 15),
  }) : _zustand = zustand {
    _zustandProStart = zustandBeimNaechstenStart;
    for (final geraet in geraete) {
      geraetHinzufuegen(geraet);
    }
    helper = ProcessBluetoothHelper(
      executable: bluetoothHelperName,
      log: log,
      start: start,
      heartbeat: heartbeat,
      callTimeout: callTimeout,
    );
  }

  /// Der echte Aufpasser, der die Attrappe startet.
  late final ProcessBluetoothHelper helper;

  /// Die Geräte, die dieser Mac kennt (alles andere ist `unknown_device`).
  final List<FakeM110> geraete = <FakeM110>[];

  /// Alle gestarteten Prozesse, ältester zuerst.
  final List<FakeHelperProcess> prozesse = <FakeHelperProcess>[];

  /// Alle Befehle außer `ping`, über alle Prozesse.
  final List<HelperRequest> befehle = <HelperRequest>[];

  /// Anzahl der `ping` (Herzschlag).
  int pings = 0;

  /// Jeder neue Prozess stirbt sofort wieder (Neustart-Sturm nachstellen).
  bool stirbtBeimStart = false;

  String _zustand;
  _Lauf? _lauf;

  /// Macht `_verbinden` in der Lücke zwischen Trennung und Zustandsmeldung
  /// zu einem `not_connected` (siehe [funkFaelltAus]).
  bool _luecke = false;

  /// Ein Zustand, der erst für den nächsten Prozessstart gilt (die Freigabe
  /// wertet macOS nur beim Start des Prozesses aus), sonst `null`.
  String? _zustandProStart;

  /// Wie oft das Hilfsprogramm gestartet wurde.
  int get starts => prozesse.length;

  /// Ob gerade ein Prozess läuft.
  bool get laeuft => _lauf != null;

  /// Der Funkzustand, den das Programm meldet.
  String get zustand => _zustand;

  /// Startet die Attrappe – als [ProcessStarter] auch einzeln verwendbar.
  Future<Process> start(String executable, List<String> arguments) async {
    final prozess = FakeHelperProcess(4200 + prozesse.length);
    prozesse.add(prozess);
    final proStart = _zustandProStart;
    if (proStart != null) {
      _zustand = proStart;
      _zustandProStart = null;
    }
    if (stirbtBeimStart) {
      prozess.beenden(1);
      return prozess;
    }
    final lauf = _Lauf(prozess);
    _lauf = lauf;
    prozess
      ..onZeile = ((zeile) => _zeile(lauf, zeile))
      // Endet stdin, endet das Programm (wie `main.swift`).
      ..onStdinEnde = (() => prozess.beenden(0))
      ..onEnde = (() => _aufraeumen(lauf));
    return prozess;
  }

  /// Meldet dem Mac ein weiteres Gerät.
  void geraetHinzufuegen(FakeM110 geraet) {
    geraet._helfer = this;
    geraete.add(geraet);
  }

  /// Ändert den Funkzustand (`poweredOff`, `unauthorized`, `poweredOn` …).
  ///
  /// Wie CoreBluetooth: verlässt der Zustand `poweredOn`, sind alle
  /// Verbindungen weg (`disconnected`), eine laufende Suche bekommt den Fehler
  /// des Zustands; wartende Befehle laufen, sobald er wieder feststeht.
  void setzeZustand(String zustand) {
    _zustand = zustand;
    _luecke = false;
    final lauf = _lauf;
    if (lauf == null || !lauf.managerDa) return;
    _sende(lauf, HelperEvent(HelperEventName.state, {'state': zustand}));
    if (zustand != 'poweredOn') {
      final suche = lauf.suche;
      final fehler = _zustandsfehler();
      if (suche != null && fehler != null) {
        lauf.suche = null;
        suche.timer.cancel();
        _fehler(lauf, suche.id, fehler.$1, fehler.$2);
      }
      for (final geraet in geraete) {
        _verbindungWeg(geraet, 'bluetooth $zustand');
      }
    }
    if (_steht(zustand)) {
      final wartend = List<HelperRequest>.of(lauf.wartend);
      lauf.wartend.clear();
      for (final befehl in wartend) {
        _ausfuehren(lauf, befehl);
      }
    }
  }

  /// Die Freigabe ändert sich in den Systemeinstellungen: macOS wertet sie nur
  /// beim Start des Prozesses aus. Der laufende Prozess behält seinen Zustand,
  /// erst ein neu gestarteter meldet [zustand].
  void aendereFreigabe(String zustand) => _zustandProStart = zustand;

  /// Bluetooth am Mac geht aus, wie CoreBluetooth es meldet: erst fallen die
  /// Verbindungen (`disconnected`), ein `connect` in dieser Lücke scheitert mit
  /// `not_connected`, der Zustand `poweredOff` kommt erst mit [setzeZustand].
  void funkFaelltAus() {
    _luecke = true;
    for (final geraet in geraete) {
      _verbindungWeg(geraet, 'disconnected');
    }
  }

  /// Der laufende Prozess stürzt ab.
  void abstuerzen({int exitCode = 1}) => _lauf?.prozess.beenden(exitCode);

  /// Der laufende Prozess hängt: er lebt, antwortet aber auf nichts mehr.
  void haengen() => _lauf?.haengt = true;

  /// Schreibt eine beliebige (auch kaputte) Zeile auf stdout.
  void sendeZeile(String zeile) => _lauf?.prozess.sendeZeile(zeile);

  /// Schreibt rohe Bytes auf stdout.
  void sendeBytes(List<int> bytes) => _lauf?.prozess.sendeBytes(bytes);

  @override
  Stream<HelperEvent> get events => helper.events;

  @override
  String get state => helper.state;

  @override
  Future<Map<String, Object?>> call(
    String op, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => helper.call(op, args);

  @override
  Future<void> refresh() => helper.refresh();

  @override
  Future<void> stop() => helper.stop();

  // ---------------------------------------------------------------------------

  void _aufraeumen(_Lauf lauf) {
    if (_lauf == lauf) _lauf = null;
    lauf.suche?.timer.cancel();
    lauf.suche = null;
    lauf.wartend.clear();
    // Mit dem Prozess sind alle seine Verbindungen weg; melden kann er nichts mehr.
    for (final geraet in geraete) {
      geraet._link?.beenden();
      geraet._link = null;
    }
  }

  void _zeile(_Lauf lauf, String zeile) {
    if (_lauf != lauf) return;
    final befehl = decodeHelperLine(zeile);
    if (befehl is! HelperRequest) {
      lauf.prozess.notiz('kasseneck-bluetooth: Zeile verworfen');
      return;
    }
    if (befehl.op == HelperOp.ping) {
      pings++;
    } else {
      befehle.add(befehl);
    }
    if (lauf.haengt) return;
    if (befehl.op == HelperOp.ping) return _ok(lauf, befehl.id);
    if (!lauf.managerDa) {
      // Erst der erste Befehl außer ping legt den Zugang zu CoreBluetooth an.
      lauf.managerDa = true;
      _sende(lauf, HelperEvent(HelperEventName.state, {'state': _zustand}));
    }
    if (!_steht(_zustand)) {
      lauf.wartend.add(befehl);
      return;
    }
    _ausfuehren(lauf, befehl);
  }

  void _ausfuehren(_Lauf lauf, HelperRequest befehl) {
    final id = befehl.id;
    final args = befehl.args;
    switch (befehl.op) {
      case HelperOp.state:
        return _ok(lauf, id, {'state': _zustand});
      case HelperOp.stopScan:
        _sucheBeenden(lauf);
        return _ok(lauf, id);
      case HelperOp.disconnect:
        final geraet = _geraet(args['device']);
        return _trennen(lauf, id, geraet);
      case HelperOp.scan ||
          HelperOp.connect ||
          HelperOp.gatt ||
          HelperOp.read ||
          HelperOp.write ||
          HelperOp.subscribe ||
          HelperOp.unsubscribe:
        final fehler = _zustandsfehler();
        if (fehler != null) return _fehler(lauf, id, fehler.$1, fehler.$2);
      default:
        return _fehler(lauf, id, HelperErrorCode.badRequest, 'unknown op');
    }

    if (befehl.op == HelperOp.scan) {
      final ms = args['ms'];
      if (ms is! int || ms < 1) {
        return _fehler(lauf, id, HelperErrorCode.badRequest, 'invalid ms');
      }
      return _suchen(lauf, id, ms);
    }

    final geraet = _geraet(args['device']);
    if (befehl.op == HelperOp.connect) {
      if (geraet == null) {
        return _fehler(
          lauf,
          id,
          HelperErrorCode.unknownDevice,
          'device not known to this mac',
        );
      }
      return _verbinden(lauf, id, geraet);
    }

    final link = geraet?._link;
    if (geraet == null || link == null || !link.bereit) {
      return _fehler(
        lauf,
        id,
        HelperErrorCode.notConnected,
        'peripheral is not connected',
      );
    }
    if (befehl.op == HelperOp.gatt) {
      return _ok(lauf, id, {'services': geraet._gatt()});
    }

    final String service;
    final String characteristic;
    try {
      service = canonicalUuid(args['service'] as String);
      characteristic = canonicalUuid(args['characteristic'] as String);
    } catch (_) {
      return _fehler(lauf, id, HelperErrorCode.badRequest, 'invalid uuid');
    }
    final eigenschaften = geraet.dienste[service]?[characteristic];
    if (eigenschaften == null) {
      return _fehler(
        lauf,
        id,
        HelperErrorCode.unknownCharacteristic,
        'characteristic not found',
      );
    }

    switch (befehl.op) {
      case HelperOp.read:
        if (!eigenschaften.contains('read')) {
          return _fehler(
            lauf,
            id,
            HelperErrorCode.unsupportedOperation,
            'characteristic cannot be read',
          );
        }
        final wert = geraet.werte[characteristic] ?? Uint8List(0);
        return _ok(lauf, id, {'data': base64Encode(wert)});
      case HelperOp.write:
        final mitAntwort = args['withResponse'];
        final data = args['data'];
        if (mitAntwort is! bool || data is! String) {
          return _fehler(lauf, id, HelperErrorCode.badRequest, 'invalid write');
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(data);
        } on FormatException {
          return _fehler(lauf, id, HelperErrorCode.badRequest, 'invalid data');
        }
        if (!eigenschaften.contains(
          mitAntwort ? 'write' : 'writeWithoutResponse',
        )) {
          return _fehler(
            lauf,
            id,
            HelperErrorCode.unsupportedOperation,
            'characteristic has no such write type',
          );
        }
        final max = mitAntwort
            ? geraet.maxWriteWithResponse
            : geraet.maxWriteWithoutResponse;
        if (bytes.length > max) {
          return _fehler(
            lauf,
            id,
            HelperErrorCode.writeFailed,
            'data longer than $max bytes for this write type',
          );
        }
        _ok(lauf, id);
        geraet._geschrieben(characteristic, bytes, mitAntwort: mitAntwort);
      case HelperOp.subscribe || HelperOp.unsubscribe:
        if (!eigenschaften.contains('notify') &&
            !eigenschaften.contains('indicate')) {
          return _fehler(
            lauf,
            id,
            HelperErrorCode.unsupportedOperation,
            'characteristic cannot notify',
          );
        }
        _ok(lauf, id);
        if (befehl.op == HelperOp.subscribe) {
          geraet._abonniert(characteristic);
        } else {
          link.abos.remove(characteristic);
        }
    }
  }

  void _suchen(_Lauf lauf, int id, int ms) {
    // Eine neue Suche beendet die vorige (deren Antwort kommt jetzt).
    _sucheBeenden(lauf);
    final suche = _Suche(id);
    lauf.suche = suche;
    suche.timer = Timer(Duration(milliseconds: ms), () {
      if (lauf.suche != suche) return;
      lauf.suche = null;
      _ok(lauf, id);
    });
    for (final geraet in geraete) {
      _gefunden(lauf, geraet);
    }
  }

  void _sucheBeenden(_Lauf lauf) {
    final suche = lauf.suche;
    if (suche == null) return;
    lauf.suche = null;
    suche.timer.cancel();
    _ok(lauf, suche.id);
  }

  /// Meldet ein sichtbares Gerät der laufenden Suche (je Gerät und Suche einmal).
  void _gefunden(_Lauf lauf, FakeM110 geraet) {
    final suche = lauf.suche;
    if (suche == null || !geraet._sichtbar) return;
    if (!suche.gesehen.add(geraet.id)) return;
    HelperEvent fund(String? name) => HelperEvent(HelperEventName.discovered, {
      'device': geraet.id,
      'name': name,
      'rssi': geraet.rssi,
      'services': geraet.beworbeneDienste,
    });
    if (geraet.nameErstSpaeter) {
      // Der Name steht erst in einer späteren Meldung: zweiter Fund mit Namen.
      _sende(lauf, fund(null));
    }
    _sende(lauf, fund(geraet.name));
  }

  void _verbinden(_Lauf lauf, int id, FakeM110 geraet) {
    final link = geraet._link;
    if (link != null) {
      if (link.bereit) {
        // Schon verbunden: `connected` erneut, dann die Antwort.
        _sende(lauf, geraet._connectedEreignis());
        _ok(lauf, id);
      } else {
        link.wartend.add(id);
      }
      return;
    }
    geraet._link = _Link()..wartend.add(id);
    if (_luecke) {
      _verbindungWeg(geraet, 'peripheral is not connected');
    } else if (geraet._erreichbar) {
      _verbunden(geraet);
    }
  }

  /// Die Verbindung steht: erst `connected`, dann die Antworten auf `connect`.
  void _verbunden(FakeM110 geraet) {
    final lauf = _lauf;
    final link = geraet._link;
    if (lauf == null || link == null || link.bereit) return;
    link.bereit = true;
    geraet.verbindungen++;
    geraet._leerlaufNeu();
    _sende(lauf, geraet._connectedEreignis());
    final wartend = List<int>.of(link.wartend);
    link.wartend.clear();
    for (final id in wartend) {
      _ok(lauf, id);
    }
  }

  void _trennen(_Lauf lauf, int id, FakeM110? geraet) {
    final link = geraet?._link;
    if (geraet == null || link == null) return _ok(lauf, id);
    _verbindungWeg(
      geraet,
      link.bereit ? 'disconnect requested' : 'connect cancelled',
    );
    _ok(lauf, id);
  }

  /// Die Verbindung ist weg: `disconnected` (nur nach `connected`), offene
  /// `connect` bekommen `not_connected`.
  void _verbindungWeg(FakeM110 geraet, String grund) {
    final lauf = _lauf;
    final link = geraet._link;
    if (lauf == null || link == null) return;
    geraet._link = null;
    link.beenden();
    if (link.bereit) {
      _sende(
        lauf,
        HelperEvent(HelperEventName.disconnected, {
          'device': geraet.id,
          'reason': grund,
        }),
      );
    }
    for (final id in link.wartend) {
      _fehler(lauf, id, HelperErrorCode.notConnected, grund);
    }
    _gefunden(lauf, geraet);
  }

  /// Ein Schalter am Gerät hat sich geändert.
  void _geraetGeaendert(FakeM110 geraet, {required bool trennt}) {
    final lauf = _lauf;
    if (lauf == null) return;
    final link = geraet._link;
    if (link != null && link.bereit && trennt && !geraet._erreichbar) {
      _verbindungWeg(geraet, 'peripheral disconnected');
    } else if (link != null && !link.bereit && geraet._erreichbar) {
      // CoreBluetooth wartet ohne Ende; ist das Gerät wieder da, steht die Verbindung.
      _verbunden(geraet);
    }
    _gefunden(lauf, geraet);
  }

  FakeM110? _geraet(Object? id) {
    if (id is! String) return null;
    final gesucht = id.toLowerCase();
    for (final geraet in geraete) {
      if (geraet.id == gesucht) return geraet;
    }
    return null;
  }

  static bool _steht(String zustand) =>
      zustand != 'unknown' && zustand != 'resetting';

  (String, String)? _zustandsfehler() => switch (_zustand) {
    'poweredOn' => null,
    'poweredOff' => (HelperErrorCode.bluetoothOff, 'bluetooth is powered off'),
    'unauthorized' => (
      HelperErrorCode.unauthorized,
      'bluetooth access not authorized',
    ),
    _ => (
      HelperErrorCode.bluetoothUnsupported,
      'bluetooth is not supported here',
    ),
  };

  void _sende(_Lauf lauf, HelperMessage nachricht) {
    if (_lauf != lauf || lauf.haengt) return;
    lauf.prozess.sende(nachricht);
  }

  /// Sendet über den laufenden Prozess (für Meldungen der Geräte).
  void _sendeJetzt(HelperMessage nachricht) {
    final lauf = _lauf;
    if (lauf != null) _sende(lauf, nachricht);
  }

  void _ok(
    _Lauf lauf,
    int id, [
    Map<String, Object?> result = const <String, Object?>{},
  ]) => _sende(lauf, HelperResponse(id, result));

  void _fehler(_Lauf lauf, int id, String code, String message) => _sende(
    lauf,
    HelperResponse(id, const {}, error: HelperError(code, message)),
  );
}

/// Nachgespielter Etikettendrucker Phomemo M110 (Werte aus dem Spike).
///
/// Dienst `ff00` mit `ff01` (lesen), `ff02` (schreiben mit und ohne Antwort)
/// und `ff03` (Meldungen). Höchstlängen 512 Byte mit, 20 Byte ohne Antwort.
/// Nach dem ersten Abo von `ff03` einer Verbindung meldet er `02 b6 00`, je
/// Paket auf `ff02` mit Antwort `01 01` und [fertigNach] nach dem letzten
/// Paket `1a 0f 0c`. Wie der echte M110 nimmt er Pakete auch ohne Abo von
/// `ff03` an, druckt dann aber nichts ([etiketten] bleibt stehen).
class FakeM110 {
  FakeM110({
    String id = fakeM110Id,
    this.name = 'Q199E00000',
    this.rssi = -58,
    this.fertigNach = const Duration(milliseconds: 2500),
    this.nameErstSpaeter = false,
    Map<String, Map<String, List<String>>>? dienste,
  }) : id = id.toLowerCase(),
       dienste = _lang(
         dienste ??
             {
               'ff00': {
                 'ff01': ['read'],
                 'ff02': ['write', 'writeWithoutResponse'],
                 'ff03': ['notify'],
               },
             },
       );

  /// CoreBluetooth-Kennung (klein).
  final String id;

  /// Name aus der Werbung (erfunden).
  final String name;

  /// Signalstärke bei der Suche.
  int rssi;

  /// Abstand zwischen dem letzten Paket und `1a 0f 0c`.
  final Duration fertigNach;

  /// Der Name kommt bei der Suche erst mit einem zweiten `discovered`.
  final bool nameErstSpaeter;

  /// Dienst → Merkmal → Eigenschaften, UUIDs lang und klein.
  final Map<String, Map<String, List<String>>> dienste;

  /// Werte für `read` je Merkmal (lang und klein); sonst leer.
  final Map<String, Uint8List> werte = <String, Uint8List>{};

  int maxWriteWithResponse = 512;
  int maxWriteWithoutResponse = 20;

  /// Alles, was auf `ff02` ankam, in Reihenfolge und über alle Verbindungen.
  final List<Uint8List> pakete = <Uint8List>[];

  /// Alle Meldungen, die auf `ff03` hinausgingen.
  final List<Uint8List> meldungen = <Uint8List>[];

  /// Gedruckte Aufträge (je `1a 0f 0c` einer).
  int etiketten = 0;

  /// Wie oft eine Verbindung zustande kam.
  int verbindungen = 0;

  FakeBluetoothHelper? _helfer;
  _Link? _link;
  bool _deckelOffen = false;
  bool _rolleFehlt = false;
  bool _aus = false;
  bool _ausserReichweite = false;
  bool _vonAnderemGeraetGehalten = false;
  Duration? _trenntLeereVerbindungNach;

  /// Ob mindestens ein Etikett gedruckt wurde.
  bool get gedruckt => etiketten > 0;

  /// Ob gerade eine Verbindung steht.
  bool get verbunden => _link?.bereit ?? false;

  /// Ob `ff03` in der laufenden Verbindung abonniert ist.
  bool get abonniert => _link?.abos.contains(_ff03) ?? false;

  /// Beworbene Dienste bei der Suche.
  List<String> get beworbeneDienste => <String>[_ff00];

  /// Deckel auf (`1a 05 99`) bzw. zu (`1a 05 98`); offen druckt er nicht.
  bool get deckelOffen => _deckelOffen;
  set deckelOffen(bool wert) {
    if (_deckelOffen == wert) return;
    _deckelOffen = wert;
    _melde(wert ? const [0x1a, 0x05, 0x99] : const [0x1a, 0x05, 0x98]);
  }

  /// Rolle fehlt (`1a 06 88`) bzw. da (`1a 06 89`); ohne Rolle druckt er nicht.
  bool get rolleFehlt => _rolleFehlt;
  set rolleFehlt(bool wert) {
    if (_rolleFehlt == wert) return;
    _rolleFehlt = wert;
    _melde(wert ? const [0x1a, 0x06, 0x88] : const [0x1a, 0x06, 0x89]);
  }

  /// Ausgeschaltet: nicht sichtbar, `connect` wartet; eine Verbindung fällt.
  bool get aus => _aus;
  set aus(bool wert) {
    if (_aus == wert) return;
    _aus = wert;
    _helfer?._geraetGeaendert(this, trennt: true);
  }

  /// Außer Reichweite: wie [aus] aus Sicht des Macs.
  bool get ausserReichweite => _ausserReichweite;
  set ausserReichweite(bool wert) {
    if (_ausserReichweite == wert) return;
    _ausserReichweite = wert;
    _helfer?._geraetGeaendert(this, trennt: true);
  }

  /// Ein anderes Gerät (z. B. die Kassen-App) hält ihn: nicht sichtbar,
  /// `connect` wartet, bis es ihn freigibt. Eine eigene Verbindung bleibt.
  bool get vonAnderemGeraetGehalten => _vonAnderemGeraetGehalten;
  set vonAnderemGeraetGehalten(bool wert) {
    if (_vonAnderemGeraetGehalten == wert) return;
    _vonAnderemGeraetGehalten = wert;
    _helfer?._geraetGeaendert(this, trennt: false);
  }

  /// Trennt eine Verbindung, über die so lange nichts geschrieben wurde.
  Duration? get trenntLeereVerbindungNach => _trenntLeereVerbindungNach;
  set trenntLeereVerbindungNach(Duration? wert) {
    _trenntLeereVerbindungNach = wert;
    _leerlaufNeu();
  }

  /// Die Verbindung reißt ab, das Gerät bleibt erreichbar.
  void verbindungAbbrechen([String grund = 'peripheral disconnected']) =>
      _helfer?._verbindungWeg(this, grund);

  bool get _erreichbar =>
      !_aus && !_ausserReichweite && !_vonAnderemGeraetGehalten;

  /// Verbundene Geräte werben nicht – die Suche sieht sie nicht.
  bool get _sichtbar => _erreichbar && _link == null;

  HelperEvent _connectedEreignis() => HelperEvent(HelperEventName.connected, {
    'device': id,
    'maxWriteWithResponse': maxWriteWithResponse,
    'maxWriteWithoutResponse': maxWriteWithoutResponse,
  });

  List<Map<String, Object?>> _gatt() => [
    for (final dienst in dienste.entries)
      {
        'uuid': dienst.key,
        'characteristics': [
          for (final merkmal in dienst.value.entries)
            {'uuid': merkmal.key, 'properties': merkmal.value},
        ],
      },
  ];

  void _abonniert(String characteristic) {
    final link = _link;
    if (link == null || !link.abos.add(characteristic)) return;
    if (characteristic == _ff03 && !link.startGemeldet) {
      link.startGemeldet = true;
      _melde(const [0x02, 0xb6, 0x00]);
    }
  }

  void _geschrieben(
    String characteristic,
    Uint8List bytes, {
    required bool mitAntwort,
  }) {
    final link = _link;
    if (link == null) return;
    _leerlaufNeu();
    if (characteristic != _ff02) return;
    pakete.add(bytes);
    if (!link.abos.contains(_ff03)) link.auftragOhneAbo = true;
    if (mitAntwort) _melde(const [0x01, 0x01]);
    link.fertig?.cancel();
    link.fertig = Timer(fertigNach, _auftragFertig);
  }

  void _auftragFertig() {
    final link = _link;
    if (link == null) return;
    final ohneAbo = link.auftragOhneAbo;
    link.auftragOhneAbo = false;
    // Ohne Zuhörer auf ff03 startet das Druckwerk nicht.
    if (ohneAbo) return;
    if (_deckelOffen) return _melde(const [0x1a, 0x05, 0x99]);
    if (_rolleFehlt) return _melde(const [0x1a, 0x06, 0x88]);
    etiketten++;
    _melde(const [0x1a, 0x0f, 0x0c]);
  }

  void _leerlaufNeu() {
    final link = _link;
    if (link == null || !link.bereit) return;
    link.leerlauf?.cancel();
    final nach = _trenntLeereVerbindungNach;
    if (nach == null) return;
    link.leerlauf = Timer(nach, () {
      if (_link == link) verbindungAbbrechen();
    });
  }

  /// Meldung auf ff03 – nur bei bestehender Verbindung mit Abo.
  void _melde(List<int> bytes) {
    final link = _link;
    final helfer = _helfer;
    if (link == null || !link.bereit || helfer == null) return;
    if (!link.abos.contains(_ff03)) return;
    final daten = Uint8List.fromList(bytes);
    meldungen.add(daten);
    helfer._sendeJetzt(
      HelperEvent(HelperEventName.notification, {
        'device': id,
        'service': _ff00,
        'characteristic': _ff03,
        'data': base64Encode(daten),
      }),
    );
  }

  static Map<String, Map<String, List<String>>> _lang(
    Map<String, Map<String, List<String>>> dienste,
  ) => {
    for (final dienst in dienste.entries)
      canonicalUuid(dienst.key): {
        for (final merkmal in dienst.value.entries)
          canonicalUuid(merkmal.key): List<String>.of(merkmal.value),
      },
  };
}

/// Ein Lauf des nachgespielten Programms (ein Prozess).
class _Lauf {
  _Lauf(this.prozess);

  final FakeHelperProcess prozess;

  /// Der Zugang zu CoreBluetooth ist angelegt (erster Befehl außer ping).
  bool managerDa = false;
  bool haengt = false;
  final List<HelperRequest> wartend = <HelperRequest>[];
  _Suche? suche;
}

class _Suche {
  _Suche(this.id);

  final int id;
  late Timer timer;
  final Set<String> gesehen = <String>{};
}

/// Verbindung eines Geräts im laufenden Prozess.
class _Link {
  bool bereit = false;
  final List<int> wartend = <int>[];
  final Set<String> abos = <String>{};
  bool startGemeldet = false;
  bool auftragOhneAbo = false;
  Timer? fertig;
  Timer? leerlauf;

  void beenden() {
    // Ein halber Auftrag ist mit der Verbindung verloren.
    fertig?.cancel();
    leerlauf?.cancel();
  }
}
