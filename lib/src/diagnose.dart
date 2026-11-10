/// Diagnose für den Support (`GET /v1/diagnosis`, Spec 1.8).
///
/// Nach Positivliste: ein Feld geht erst mit, wenn es hier eingetragen ist.
/// Nie dabei: Token-Hashes, Kopplung, Zertifikate, Schlüssel, Felder einer
/// neueren Fassung. Sechsstellige Zahlen im Log (Kopplungscodes) werden
/// geschwärzt.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config/model.dart';
import 'log/aufbewahrung.dart';

/// So viele Logzeilen liefert die Diagnose ohne Angabe (Spec 1.8).
const int diagnoseZeilenVorgabe = 200;

/// Höchstens so viele Logzeilen (Spec 1.8). 500 Zeilen sind rund 60 KB und
/// reichen für die letzte Viertelstunde eines lauten Tages.
const int diagnoseZeilenHoechstens = 500;

/// So viele Bytes vom Ende einer Logdatei werden höchstens gelesen. 500
/// Zeilen passen mit Luft hinein; eine 5-MB-Datei ganz zu lesen, nur um ihr
/// Ende zu zeigen, wäre unnötig.
const int _logEndeBytes = 256 * 1024;

/// Die Zeilenzahl aus `?lines=`: Vorgabe [diagnoseZeilenVorgabe], begrenzt
/// auf 0 bis [diagnoseZeilenHoechstens].
int diagnoseZeilen(String? roh) {
  final zahl = int.tryParse(roh ?? '');
  if (zahl == null) return diagnoseZeilenVorgabe;
  return zahl.clamp(0, diagnoseZeilenHoechstens);
}

/// Schwärzt jede alleinstehende sechsstellige Zahl (Kopplungscodes).
///
/// Längere Zahlen (TID, Transaktionskennung) und Zeitstempel bleiben, sie
/// stehen nie als genau sechs Ziffern für sich.
String schwaerze(String zeile) =>
    zeile.replaceAll(RegExp(r'(?<!\d)\d{6}(?!\d)'), '******');

/// Die Konfiguration nach Positivliste.
Map<String, Object?> konfigurationFuerDiagnose(
  AgentConfig config,
) => <String, Object?>{
  'port': config.port,
  'httpsPort': config.httpsPort,
  'updateChannel': config.updateChannel,
  'pairedTokens': config.tokenHashes.length,
  'allowDevOrigins': config.allowDevOrigins,
  'disabledFeatures': config.disabledFeatures,
  'printers': <Map<String, Object?>>[
    for (final d in config.printers)
      <String, Object?>{
        ...d.toApiJson(),
        'model': d.model,
        'serial': d.serial,
        'mac': d.mac,
        'identifiedAt': d.identifiedAt?.toIso8601String(),
        'identitySource': d.identitySource?.wireName,
        'statusCapableAt': d.statusCapableAt?.toIso8601String(),
      },
  ],
  'terminal': switch (config.terminal) {
    null => null,
    final t => <String, Object?>{
      'kind': t.kind,
      'host': t.host,
      'port': t.port,
      'tid': t.tid,
      'mac': t.mac,
      'confirmedAt': t.confirmedAt?.toIso8601String(),
    },
  },
  'bluetoothDevices': <String>[for (final g in config.bluetoothDevices) g.name],
};

/// Die letzten [anzahl] Zeilen des Logs in [verzeichnis] (älteste zuerst):
/// aus `connect.log`, reicht das nicht, davor aus dem jüngsten Archiv.
/// Wirft nie.
List<String> letzteLogzeilen(Directory verzeichnis, int anzahl) {
  if (anzahl <= 0) return const <String>[];
  final zeilen = _ende(File(p.join(verzeichnis.path, 'connect.log')), anzahl);
  if (zeilen.length < anzahl) {
    final archiv = _juengstesArchiv(verzeichnis);
    if (archiv != null) {
      zeilen.insertAll(0, _ende(archiv, anzahl - zeilen.length));
    }
  }
  return zeilen;
}

List<String> _ende(File datei, int anzahl) {
  try {
    if (!datei.existsSync()) return <String>[];
    final groesse = datei.lengthSync();
    final lesen = datei.openSync();
    final List<int> bytes;
    try {
      final ab = groesse > _logEndeBytes ? groesse - _logEndeBytes : 0;
      lesen.setPositionSync(ab);
      bytes = lesen.readSync(groesse - ab);
    } finally {
      lesen.closeSync();
    }
    final alle = const LineSplitter()
        .convert(utf8.decode(bytes, allowMalformed: true))
        .where((z) => z.isNotEmpty)
        .toList();
    return alle.length > anzahl ? alle.sublist(alle.length - anzahl) : alle;
  } on FileSystemException {
    // Ohne lesbares Log fehlen der Diagnose eben die Zeilen.
    return <String>[];
  }
}

File? _juengstesArchiv(Directory verzeichnis) {
  if (!verzeichnis.existsSync()) return null;
  final archive = <LogArchiv>[];
  for (final datei in verzeichnis.listSync().whereType<File>()) {
    final archiv = LogArchiv.ausName(p.basename(datei.path), 0);
    if (archiv != null) archive.add(archiv);
  }
  if (archive.isEmpty) return null;
  archive.sort(LogArchiv.chronologisch);
  return File(p.join(verzeichnis.path, archive.last.name));
}
