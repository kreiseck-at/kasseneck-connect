import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../net/arp.dart';
import 'abfrage.dart';
import 'discovery.dart';
import 'funde.dart';
import 'kennung.dart';
import 'lage.dart';
import 'queue.dart';

/// Zeitbudget einer Erkennung. Sie läuft im Hintergrund über die Warteschlange
/// des Druckers, niemand wartet an der Kasse darauf; zwei Sekunden reichen
/// auch für einen Drucker im WLAN, der erst aufwachen muss.
const Duration erkennungsBudget = Duration(seconds: 2);

/// Frühestens so oft wird ein Drucker ohne Kennung erneut gefragt. Ein Gerät,
/// das auf `GS I` nicht antwortet, soll nicht bei jedem Bon gefragt werden.
const Duration erkennungsAbstand = Duration(minutes: 10);

/// Ermittelt Modell, Seriennummer und MAC eines Druckers (Spec 1.1).
///
/// Quellen: mDNS-TXT aus der letzten Suche, `GS I 67/68` über 9100, MAC aus
/// der ARP-Tabelle (nur im selben Netz). Wirft nie.
class DruckerErkennung {
  DruckerErkennung({
    required EscPosAbfrage abfrage,
    required ArpTabelle arp,
    required InterfaceProbe schnittstellen,
    FundGedaechtnis? funde,
    this.budget = erkennungsBudget,
  }) : _abfrage = abfrage,
       _arp = arp,
       _schnittstellen = schnittstellen,
       _funde = funde;

  final EscPosAbfrage _abfrage;
  final ArpTabelle _arp;
  final InterfaceProbe _schnittstellen;
  final FundGedaechtnis? _funde;

  /// Zeitbudget der Abfrage-Verbindung.
  final Duration budget;

  Future<ErkannteKennung> erkenne(PrinterConfig drucker) async {
    final fund = _funde?.unter(drucker.host, drucker.port);
    var model = fund?.model;
    var modelQuelle = model == null ? null : KennungsQuelle.mdns;
    var serial = fund?.serial;
    var serialQuelle = serial == null ? null : KennungsQuelle.mdns;

    if (drucker.kind == PrinterKind.tcp9100) {
      final antworten = await _abfrage.frage(
        drucker.host,
        drucker.port,
        fragen: const <EscPosFrage>{
          EscPosFrage.modell,
          EscPosFrage.seriennummer,
        },
        budget: budget,
      );
      if (antworten.modell != null) {
        model = antworten.modell;
        modelQuelle = KennungsQuelle.escpos;
      }
      if (antworten.seriennummer != null) {
        serial = antworten.seriennummer;
        serialQuelle = KennungsQuelle.escpos;
      }
    }

    final mac = await macImSelbenNetz(drucker.host, _arp, _schnittstellen);
    return ErkannteKennung(
      model: model,
      modelQuelle: modelQuelle,
      serial: serial,
      serialQuelle: serialQuelle,
      mac: mac,
    );
  }
}

/// Die MAC zu [host], aber nur, wenn [host] im selben Netz wie eine eigene
/// Schnittstelle liegt (sonst nennte ARP allenfalls den Router).
Future<String?> macImSelbenNetz(
  String host,
  ArpTabelle arp,
  InterfaceProbe schnittstellen, {
  Duration frist = arpFrist,
}) async {
  final List<LocalInterface> eigene;
  try {
    eigene = await schnittstellen();
  } on Object {
    // Ohne Schnittstellenliste kein Netzvergleich – dann keine MAC.
    return null;
  }
  if (!gleichesNetz(host, eigene)) return null;
  return arp.macFuer(host, frist: frist);
}

/// Pflegt die Kennungen: nach dem Anlegen und beim ersten erfolgreichen
/// Kontakt eines Druckers ohne Kennung.
///
/// Läuft immer über die Warteschlange des Druckers – die Abfrage-Verbindung
/// steht nie neben einem Auftrag. Abgeschaltet über `printer_identity`.
class Kennungspflege {
  Kennungspflege({
    required this.store,
    required this.queue,
    required this.erkennung,
    required this.lagen,
    AgentLog? log,
    DateTime Function()? clock,
  }) : _log = log,
       _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final PrintQueue queue;
  final DruckerErkennung erkennung;
  final DruckerLagen lagen;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Laufende Erkennung je Drucker – zwei Anstöße teilen sich eine.
  final Map<String, Future<void>> _laufend = <String, Future<void>>{};

  /// Nach dem Anlegen bzw. Ändern der Adresse: sofort erkennen.
  Future<void> nachAnlegen(String id) => _erkenne(id, sofort: true);

  /// Nach einem erfolgreichen Kontakt: erkennen, wenn die Kennung fehlt und
  /// der letzte Versuch lange genug her ist. Kehrt sofort zurück.
  void nachKontakt(String id) => unawaited(_erkenne(id, sofort: false));

  Future<void> _erkenne(String id, {required bool sofort}) {
    final laufend = _laufend[id];
    if (laufend != null) return laufend;
    final arbeit = _arbeit(
      id,
      sofort: sofort,
    ).whenComplete(() => _laufend.remove(id));
    _laufend[id] = arbeit;
    return arbeit;
  }

  Future<void> _arbeit(String id, {required bool sofort}) async {
    try {
      final config = await store.load();
      if (!config.aktiv(Neuerung.druckerKennung)) return;
      final drucker = _finde(config, id);
      if (drucker == null) return;
      final lage = lagen.von(id);
      if (!sofort) {
        if (drucker.hatKennung) return;
        final zuletzt = lage.letzteErkennung;
        if (zuletzt != null &&
            _clock().difference(zuletzt) < erkennungsAbstand) {
          return;
        }
      }
      lage.letzteErkennung = _clock();
      final erkannt = await queue.exclusive(
        id,
        () => erkennung.erkenne(drucker),
      );
      if (erkannt.leer) return;
      await _speichere(drucker, erkannt);
    } on Object catch (e) {
      // Ohne Kennung druckt der Drucker wie bis 1.4.2; der nächste Kontakt
      // versucht es wieder.
      _log?.warn('Kennung von $id ließ sich nicht ermitteln: $e');
    }
  }

  Future<void> _speichere(PrinterConfig vorher, ErkannteKennung erkannt) async {
    PrinterConfig? neu;
    await store.mutate((config) {
      final printers = config.printers.toList();
      final index = printers.indexWhere((p) => p.id == vorher.id);
      if (index < 0) return config;
      final aktuell = printers[index];
      // Inzwischen eine andere Adresse: die Erkennung galt dem alten Gerät.
      if (aktuell.host != vorher.host || aktuell.port != vorher.port) {
        return config;
      }
      neu = ergaenzeKennung(aktuell, erkannt, _clock().toUtc());
      if (neu == null) return config;
      printers[index] = neu!;
      return config.copyWith(printers: printers);
    });
    final gespeichert = neu;
    if (gespeichert == null) return;
    _log?.info(
      'Drucker ${gespeichert.id} erkannt: '
      'Modell ${gespeichert.model ?? '–'}, '
      'Seriennummer ${gespeichert.serial ?? '–'}, '
      'MAC ${gespeichert.mac ?? '–'}.',
    );
  }

  static PrinterConfig? _finde(AgentConfig config, String id) {
    for (final drucker in config.printers) {
      if (drucker.id == id) return drucker;
    }
    return null;
  }
}
