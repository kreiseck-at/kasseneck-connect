import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../config/neuerungen.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../process_runner.dart';
import 'vorgaenge.dart';

/// Längste Schlafsperre (Spec 1.5: 6 min, so lang wie der längste Vorgang).
/// `caffeinate` bekommt sie als `-t` mit und endet dann von selbst, auch wenn
/// Connect die Sperre nie aufhebt.
const Duration schlafsperreHoechstdauer = vorgangHoechstdauer;

/// Windows: so oft setzt Connect den Leerlauf-Zähler zurück. Die kürzeste
/// Ruhezustandsfrist in den Energieoptionen ist eine Minute.
const Duration windowsAuffrischen = Duration(seconds: 30);

/// `ES_SYSTEM_REQUIRED` (WinBase.h): setzt den Leerlauf-Zähler des Systems
/// zurück, ohne einen Zustand zu hinterlassen.
const int _esSystemRequired = 0x00000001;

/// Setzt unter Windows den Leerlauf-Zähler zurück (Tests ersetzen es).
typedef LeerlaufZuruecksetzen = void Function();

/// Ruft `SetThreadExecutionState(ES_SYSTEM_REQUIRED)` aus `kernel32.dll`.
///
/// Bewusst OHNE `ES_CONTINUOUS`: dieser Zustand hängt am Thread, und ein
/// Dart-Isolate wechselt zwischen Threads; eine so gesetzte Sperre ließe sich
/// womöglich nie mehr aufheben. Ohne `ES_CONTINUOUS` setzt jeder Aufruf nur
/// den Zähler zurück – endet Connect, endet die Sperre mit dem nächsten
/// Leerlauf von selbst (im Gerätetest zu bestätigen).
void windowsLeerlaufZuruecksetzen() {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setze = kernel32
      .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'SetThreadExecutionState',
      );
  setze(_esSystemRequired);
}

/// Verhindert den Ruhezustand des Rechners, solange ein Vorgang läuft – nie
/// während der ganzen Öffnungszeit (Spec 1.5).
///
/// - macOS: ein `caffeinate -i -w <pid> -t 360` für alle Vorgänge zusammen;
///   es endet mit dem letzten Vorgang, mit Connect (`-w`) oder nach 6 min.
/// - Windows: Leerlauf-Zähler alle 30 s zurücksetzen, höchstens 6 min.
/// - Linux: keine.
///
/// Abgeschaltet über `sleep_lock`.
class Schlafsperre implements BetriebsBeobachter {
  Schlafsperre({
    required this.store,
    required String betriebssystem,
    required ProcessStarter start,
    int? eigenePid,
    LeerlaufZuruecksetzen? windows,
    AgentLog? log,
    this.auffrischen = windowsAuffrischen,
    this.hoechstdauer = schlafsperreHoechstdauer,
  }) : _os = betriebssystem,
       _start = start,
       _pid = eigenePid ?? pid,
       _windows = windows ?? windowsLeerlaufZuruecksetzen,
       _log = log;

  final ConfigStore store;
  final String _os;
  final ProcessStarter _start;
  final int _pid;
  final LeerlaufZuruecksetzen _windows;
  final AgentLog? _log;
  final Duration auffrischen;
  final Duration hoechstdauer;

  Process? _caffeinate;
  Timer? _takt;
  Timer? _ende;

  /// Ein- und Ausschalten laufen nacheinander (ein schnelles „belegt, frei“
  /// darf kein `caffeinate` übrig lassen).
  Future<void> _kette = Future<void>.value();

  /// Ist die letzte angestoßene Änderung erledigt (Tests)?
  Future<void> get erledigt => _kette;

  /// Ob gerade eine Sperre besteht.
  bool get aktiv => _caffeinate != null || _takt != null;

  @override
  void belegt() => _reihe(() async {
    if (!(await store.load()).aktiv(Neuerung.schlafsperre)) return;
    switch (_os) {
      case 'macos':
        await _caffeinateStarten();
      case 'windows':
        _windowsStarten();
    }
  });

  @override
  void frei() => _reihe(() async => _aufheben());

  Future<void> _caffeinateStarten() async {
    if (_caffeinate != null) return;
    final Process prozess;
    try {
      prozess = await _start('caffeinate', <String>[
        '-i',
        '-w',
        '$_pid',
        '-t',
        '${hoechstdauer.inSeconds}',
      ]);
    } on ProcessException catch (e) {
      // Ohne caffeinate schläft der Rechner wie bis 1.4.2.
      _log?.warn('Schlafsperre nicht möglich: ${e.message}');
      return;
    }
    // caffeinate schreibt nichts; die Ströme trotzdem leeren, damit nichts
    // hängt.
    prozess.stdout.drain<void>().ignore();
    prozess.stderr.drain<void>().ignore();
    _caffeinate = prozess;
  }

  void _windowsStarten() {
    if (_takt != null) return;
    void zuruecksetzen() {
      try {
        _windows();
      } on Object catch (e) {
        // Dann eben ohne Sperre – wie bis 1.4.2.
        _log?.warn('Schlafsperre (Windows) nicht möglich: $e');
        _aufheben();
      }
    }

    _takt = Timer.periodic(auffrischen, (_) => zuruecksetzen());
    _ende = Timer(hoechstdauer, _aufheben);
    zuruecksetzen();
  }

  void _aufheben() {
    _caffeinate?.kill();
    _caffeinate = null;
    _takt?.cancel();
    _takt = null;
    _ende?.cancel();
    _ende = null;
  }

  void _reihe(Future<void> Function() schritt) {
    _kette = _kette.then((_) async {
      try {
        await schritt();
      } on Object catch (e) {
        _log?.warn('Schlafsperre: $e');
      }
    });
  }
}
