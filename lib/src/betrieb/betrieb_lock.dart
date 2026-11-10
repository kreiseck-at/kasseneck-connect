import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/neuerungen.dart';
import '../config/store.dart';
import '../log/logger.dart';
import 'vorgaenge.dart';

/// Name der Datei, die einen laufenden Vorgang anzeigt (im Datenordner).
const String betriebLockName = 'betrieb.lock';

/// Ab diesem Alter gilt `betrieb.lock` als verwaist (Spec 1.5: 6 min, so lang
/// wie der längste Vorgang). Stürzt Connect mitten in einer Zahlung ab, bleibt
/// die Datei liegen – sie hält ein Update dann höchstens so lange auf.
const Duration betriebLockFrisch = vorgangHoechstdauer;

/// So lange wartet das postinstall eines Updates höchstens auf das Ende eines
/// Vorgangs (Spec 1.5: 5 min); danach geht die Installation weiter.
const Duration installerWarteHoechstens = Duration(minutes: 5);

/// Abstand, in dem das Warten nach der Datei sieht.
const Duration installerWarteTakt = Duration(seconds: 2);

/// Die Datei `betrieb.lock` in [verzeichnis].
File betriebLockDatei(Directory verzeichnis) =>
    File(p.join(verzeichnis.path, betriebLockName));

/// Ob eine `betrieb.lock`, zuletzt geändert um [geaendert], um [jetzt] noch
/// als frisch gilt.
bool betriebLockIstFrisch(DateTime geaendert, DateTime jetzt) {
  final alter = jetzt.difference(geaendert);
  // Eine Datei aus der Zukunft (Uhr verstellt) zählt als verwaist: lieber
  // ein Update zu früh als nie.
  return !alter.isNegative && alter < betriebLockFrisch;
}

/// Schreibt `betrieb.lock`, solange ein Vorgang läuft, und löscht sie danach.
///
/// Das postinstall eines Updates liest sie (`kasseneck-connect
/// betrieb-abwarten`): zwischen dem Öffnen des Installers und der Bestätigung
/// durch den Menschen kann eine Zahlung beginnen, und der Neustart danach
/// darf sie nicht abreißen. Abgeschaltet über `busy_lock`: dann keine Datei.
class BetriebsLock implements BetriebsBeobachter {
  BetriebsLock({required this.store, AgentLog? log, DateTime Function()? clock})
    : _log = log,
      _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Schreiben und Löschen laufen nacheinander: ein schnelles „belegt, frei“
  /// darf nicht als liegengebliebene Datei enden.
  Future<void> _kette = Future<void>.value();

  File get datei => betriebLockDatei(store.paths.directory);

  /// Ist die letzte angestoßene Dateiänderung erledigt (Tests)?
  Future<void> get erledigt => _kette;

  /// Wann der erste Vorgang der laufenden Belegung begann.
  DateTime? _seit;

  @override
  void belegt() {
    _seit = _clock();
    _reihe(_schreiben);
  }

  /// Schreibt die Datei neu: ihr Änderungszeitpunkt, an dem das postinstall
  /// die Frische misst, rückt auf jetzt.
  @override
  void weiterhin() => _reihe(_schreiben);

  Future<void> _schreiben() async {
    if (!(await store.load()).aktiv(Neuerung.betriebSperre)) return;
    final jetzt = _clock().toUtc();
    await datei.writeAsString(
      jsonEncode(<String, Object?>{
        'pid': pid,
        'seit': (_seit?.toUtc() ?? jetzt).toIso8601String(),
        'stand': jetzt.toIso8601String(),
      }),
      flush: true,
    );
  }

  @override
  void frei() {
    _seit = null;
    _reihe(() async {
      if (datei.existsSync()) await datei.delete();
    });
  }

  void _reihe(Future<void> Function() schritt) {
    _kette = _kette.then((_) async {
      try {
        await schritt();
      } on FileSystemException catch (e) {
        // Ohne Datei wartet der Installer nicht – wie bis 1.4.2.
        _log?.warn('$betriebLockName: ${e.message}');
      }
    });
  }
}

/// Wartet, solange [datei] frisch ist – höchstens [hoechstens]. Für das
/// postinstall (`kasseneck-connect betrieb-abwarten`); wirft nie.
///
/// Liefert, wie lange gewartet wurde (`Duration.zero`, wenn gar nicht).
Future<Duration> warteAufFreienBetrieb(
  File datei, {
  Duration hoechstens = installerWarteHoechstens,
  Duration takt = installerWarteTakt,
  DateTime Function()? clock,
  Future<void> Function(Duration)? schlafe,
}) async {
  final uhr = clock ?? DateTime.now;
  final warte = schlafe ?? (Duration d) => Future<void>.delayed(d);
  final beginn = uhr();
  var gewartet = Duration.zero;
  while (true) {
    final DateTime geaendert;
    try {
      if (!datei.existsSync()) break;
      geaendert = datei.lastModifiedSync();
    } on FileSystemException {
      // Eben gelöscht oder nicht lesbar: nicht warten.
      break;
    }
    if (!betriebLockIstFrisch(geaendert, uhr())) break;
    if (uhr().difference(beginn) >= hoechstens) break;
    await warte(takt);
    gewartet += takt;
  }
  return gewartet;
}
