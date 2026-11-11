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
import 'wiederfinden.dart';

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
    DateTime Function()? clock,
    this.budget = erkennungsBudget,
  }) : _clock = clock ?? DateTime.now,
       _abfrage = abfrage,
       _arp = arp,
       _schnittstellen = schnittstellen,
       _funde = funde;

  final EscPosAbfrage _abfrage;
  final ArpTabelle _arp;
  final InterfaceProbe _schnittstellen;
  final FundGedaechtnis? _funde;
  final DateTime Function() _clock;

  /// Zeitbudget der Abfrage-Verbindung.
  final Duration budget;

  /// Erkennt [drucker]. Ohne [mitGsI] geht nur `DLE EOT 2` hinaus (kein
  /// `GS I`, siehe `PrinterConfig.idQueryUnansweredAt`).
  Future<ErkannteKennung> erkenne(
    PrinterConfig drucker, {
    bool mitGsI = true,
  }) async {
    final fund = _funde?.unter(drucker.host, drucker.port);
    var model = fund?.model;
    var modelQuelle = model == null ? null : KennungsQuelle.mdns;
    var serial = fund?.serial;
    var serialQuelle = serial == null ? null : KennungsQuelle.mdns;
    DateTime? statusfaehigAm;
    DateTime? gsIOhneAntwortAm;
    var verbunden = false;

    if (drucker.kind == PrinterKind.tcp9100) {
      final antworten = await _abfrage.frage(
        drucker.host,
        drucker.port,
        fragen: mitGsI
            ? const <EscPosFrage>{EscPosFrage.modell, EscPosFrage.seriennummer}
            : const <EscPosFrage>{},
        budget: budget,
      );
      verbunden = antworten.verbunden;
      if (antworten.gsIOhneAntwort && antworten.modell == null) {
        gsIOhneAntwortAm = _clock();
      }
      if (antworten.modell != null) {
        model = antworten.modell;
        modelQuelle = KennungsQuelle.escpos;
      }
      if (antworten.seriennummer != null) {
        serial = antworten.seriennummer;
        serialQuelle = KennungsQuelle.escpos;
      }
      if (antworten.offlineGrund != null) statusfaehigAm = _clock();
    }

    var mac = await macImSelbenNetz(drucker.host, _arp, _schnittstellen);
    // Steht die MAC auch unter einer anderen Adresse (Repeater mit MAC-NAT,
    // Bridge), kennzeichnet sie kein Gerät und wird nicht gespeichert.
    if (mac != null &&
        adressenMitMac(await _arp.alle(), mac).any((h) => h != drucker.host)) {
      mac = null;
    }
    return ErkannteKennung(
      model: model,
      modelQuelle: modelQuelle,
      serial: serial,
      serialQuelle: serialQuelle,
      mac: mac,
      statusfaehigAm: statusfaehigAm,
      gsIOhneAntwortAm: gsIOhneAntwortAm,
      verbunden: verbunden,
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

/// Pflegt die Kennungen: beim Anlegen (`PUT`), nach einer Druckersuche und
/// auf Zuruf (`POST /v1/printers/{id}/status`) – nie wegen eines Bons. Ein
/// Drucker, dessen Modell nicht bewiesen ist, sieht vor seinen Bons so nie
/// eine fremde Verbindung.
///
/// `GS I` geht nach der Suche und auf Zuruf nur an ein Gerät, das es nicht
/// schon einmal unbeantwortet ließ (`PrinterConfig.idQueryUnansweredAt`);
/// beim Anlegen immer – dann folgt ohnehin ein Testdruck.
///
/// Läuft immer über die Warteschlange des Druckers – die Abfrage-Verbindung
/// steht nie neben einem Auftrag. Abgeschaltet über `printer_identity`.
class Kennungspflege {
  Kennungspflege({
    required this.store,
    required this.queue,
    required this.erkennung,
    required this.lagen,
    this.wiederfinder,
    AgentLog? log,
    DateTime Function()? clock,
  }) : _log = log,
       _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final PrintQueue queue;
  final DruckerErkennung erkennung;
  final DruckerLagen lagen;

  /// Sucht den alten Drucker, bevor eine neue Kennung übernommen wird.
  DruckerWiederfinder? wiederfinder;

  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Laufende Erkennung je Drucker – zwei Anstöße teilen sich eine.
  final Map<String, Future<void>> _laufend = <String, Future<void>>{};

  /// Wartet auf laufende Erkennungen (Agent hält an).
  Future<void> erledigt() => Future.wait(_laufend.values.toList());

  /// Nach dem Anlegen bzw. Ändern der Adresse: sofort erkennen.
  Future<void> nachAnlegen(String id) => _erkenne(id, sofort: true);

  /// Auf Zuruf: erkennen, wenn Kennung oder ein über `GS I 67` gelesenes
  /// Modell fehlt und der letzte Versuch lange genug her ist.
  Future<void> aufZuruf(String id) => _erkenne(id, sofort: false);

  /// Nach einer Druckersuche: alle Drucker ohne gelesenes Modell erkennen,
  /// im Hintergrund.
  Future<void> nachSuche() async {
    try {
      for (final drucker in (await store.load()).printers) {
        if (_unvollstaendig(drucker)) unawaited(aufZuruf(drucker.id));
      }
    } on Object catch (e) {
      _log?.warn('Kennungen nach der Suche: $e');
    }
  }

  static bool _unvollstaendig(PrinterConfig drucker) =>
      !drucker.hatKennung ||
      (drucker.kind == PrinterKind.tcp9100 &&
          drucker.modelSource != KennungsQuelle.escpos);

  /// Unter der Adresse von [drucker] antwortet dauerhaft ein anderer Drucker
  /// mit [neueSerie]: erst gründlich nach dem alten suchen; ist er nirgends,
  /// die Kennung des neuen übernehmen (Logzeile, `relocations` mit
  /// `kind: replaced`). Gedruckt wurde ohnehin an die Adresse wie bis 1.4.2.
  /// Im Hintergrund; wirft nie.
  void ersetzen(PrinterConfig drucker, String neueSerie) {
    if (_laufend.containsKey(drucker.id)) return;
    final arbeit = _ersetzen(drucker, neueSerie).whenComplete(() {
      _laufend.remove(drucker.id);
    });
    _laufend[drucker.id] = arbeit;
  }

  Future<void> _ersetzen(PrinterConfig drucker, String neueSerie) async {
    final lage = lagen.von(drucker.id);
    try {
      final suche = wiederfinder;
      if (suche != null) {
        final ergebnis = await suche.gruendlichMitAuskunft(drucker.id);
        if (ergebnis.fund != null) return;
        if (!ergebnis.gesucht) {
          // Nicht gesucht (Zahlung, abgeschaltet): später wieder.
          lage.ersetzenAngestossen = false;
          return;
        }
      }
      final erkannt = await queue.exclusive(
        drucker.id,
        () => _erkenneUndMerke(drucker),
      );
      final serie = erkannt.serial;
      if (serie == null ||
          erkannt.serialQuelle != KennungsQuelle.escpos ||
          !gleicheKennung(serie, neueSerie)) {
        lage.ersetzenAngestossen = false;
        return;
      }
      await _uebernimm(drucker, erkannt, serie);
    } on Object catch (e) {
      lage.ersetzenAngestossen = false;
      _log?.warn('Kennung von ${drucker.id} ließ sich nicht übernehmen: $e');
    }
  }

  Future<void> _uebernimm(
    PrinterConfig vorher,
    ErkannteKennung erkannt,
    String serie,
  ) async {
    var geschrieben = false;
    final jetzt = _clock().toUtc();
    await store.mutate((config) {
      final printers = config.printers.toList();
      final index = printers.indexWhere((p) => p.id == vorher.id);
      if (index < 0) return config;
      final aktuell = printers[index];
      // Inzwischen anders eingerichtet oder schon geändert: nichts tun.
      if (aktuell.host != vorher.host ||
          aktuell.port != vorher.port ||
          aktuell.serial != vorher.serial) {
        return config;
      }
      final ausGsI = erkannt.modelQuelle == KennungsQuelle.escpos;
      printers[index] = PrinterConfig(
        id: aktuell.id,
        name: aktuell.name,
        kind: aktuell.kind,
        host: aktuell.host,
        port: aktuell.port,
        devid: aktuell.devid,
        model: ausGsI ? erkannt.model : null,
        modelSource: ausGsI ? KennungsQuelle.escpos : null,
        serial: serie,
        mac: normalizeMac(erkannt.mac),
        identifiedAt: jetzt,
        identitySource: KennungsQuelle.escpos,
        // Ein anderes Gerät: ob es auf DLE EOT antwortet, zeigt sich neu.
        extras: aktuell.extras,
      );
      geschrieben = true;
      return config
          .copyWith(printers: printers)
          .mitAdressWechsel(
            AdressWechsel(
              at: jetzt,
              art: GeraeteArt.ersetzt,
              kennung: aktuell.id,
              von: vorher.serial ?? '',
              nach: serie,
            ),
          );
    });
    if (!geschrieben) return;
    lagen.vergiss(vorher.id);
    _log?.info(
      'Drucker ${vorher.id}: unter ${vorher.host}:${vorher.port} steht '
      'dauerhaft ein anderer Drucker (Seriennummer $serie statt '
      '${vorher.serial}), der alte ist nirgends zu finden – Kennung '
      'übernommen.',
    );
  }

  Future<void> _erkenne(String id, {required bool sofort}) {
    final laufend = _laufend[id];
    if (laufend != null) return laufend;
    final arbeit = _arbeit(id, sofort: sofort).whenComplete(() {
      // Block statt Pfeil: `remove` liefert genau diese Zukunft, und
      // whenComplete wartete sonst auf sich selbst.
      _laufend.remove(id);
    });
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
        if (!_unvollstaendig(drucker)) return;
        final zuletzt = lage.letzteErkennung;
        if (zuletzt != null &&
            _clock().difference(zuletzt) < erkennungsAbstand) {
          return;
        }
      }
      lage.letzteErkennung = _clock();
      // `GS I` nur, wo es nicht schon einmal unbeantwortet blieb – außer
      // beim Anlegen (Testdruck folgt) und bei gelesenem Modell (das Gerät
      // kennt `GS I`).
      final mitGsI =
          sofort ||
          drucker.idQueryUnansweredAt == null ||
          drucker.modelSource == KennungsQuelle.escpos;
      final erkannt = await queue.exclusive(
        id,
        () => _erkenneUndMerke(drucker, mitGsI: mitGsI),
      );
      if (erkannt.leer) return;
      await _speichere(drucker, erkannt);
    } on Object catch (e) {
      // Ohne Kennung druckt der Drucker wie bis 1.4.2; der nächste Kontakt
      // versucht es wieder.
      _log?.warn('Kennung von $id ließ sich nicht ermitteln: $e');
    }
  }

  /// Erkennt [drucker] in seiner Warteschlange und merkt sich dort eine
  /// stehende Abfrage-Verbindung – bevor der nächste Auftrag beginnt: gibt
  /// der Drucker sie langsam frei, wartet ein Bon direkt danach auf sie
  /// (`DruckerLage.ebenAbgefragt`), statt zu scheitern.
  Future<ErkannteKennung> _erkenneUndMerke(
    PrinterConfig drucker, {
    bool mitGsI = true,
  }) async {
    final erkannt = await erkennung.erkenne(drucker, mitGsI: mitGsI);
    if (erkannt.verbunden) lagen.von(drucker.id).abgefragt();
    return erkannt;
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
