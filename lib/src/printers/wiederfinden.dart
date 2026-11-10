import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import '../net/arp.dart';
import 'abfrage.dart';
import 'discovery.dart';
import 'erkennung.dart' show macImSelbenNetz;
import 'kennung.dart';
import 'queue.dart';
import 'registry.dart';

/// Zeitbudget des schnellen Wiederfindens (Spec 1.3: höchstens 4 s). Es läuft
/// mitten in einem Auftrag, nachdem die Verbindung vor dem ersten Byte
/// scheiterte; länger soll der Kassier nicht auf den Bon warten.
const Duration schnellesWiederfindenBudget = Duration(seconds: 4);

/// Höchstens eine gründliche Suche je Drucker in diesem Abstand (Spec 1.3):
/// ein ausgeschalteter Drucker soll keinen Dauerscan auslösen.
const Duration gruendlichAbstand = Duration(minutes: 2);

/// Zeit für die Seriennummer eines Kandidaten (eigene Abfrage-Verbindung).
const Duration kandidatAbfrageBudget = Duration(milliseconds: 800);

/// So viele Adressen mit offenem Druckport fragt die gründliche Suche
/// höchstens nach der Seriennummer – mehr Bondrucker hat kein Laden, und die
/// Suche soll begrenzt bleiben.
const int gruendlichHoechstKandidaten = 32;

/// Ereignis: ein Drucker ist still unter eine neue Adresse gezogen
/// (`{printerId, from, to}`). Für Log und Diagnose; die Kasse zeigt nichts.
const String eventPrinterRelocated = 'printer.relocated';

/// Ein Gerät unter einer anderen Adresse, das der gesuchte Drucker sein kann.
class DruckerKandidat {
  const DruckerKandidat({
    required this.host,
    required this.port,
    this.mac,
    this.serie,
  });

  final String host;
  final int port;

  /// MAC aus der ARP-Tabelle, wenn bekannt.
  final String? mac;

  /// Seriennummer, die das Gerät selbst genannt hat (mDNS-TXT oder `GS I`).
  final String? serie;
}

/// Ob [kandidat] nachweislich [drucker] ist.
///
/// Mit gespeicherter Seriennummer zählt nur dieselbe genannte Seriennummer;
/// nur mit MAC dieselbe MAC (der Aufrufer nimmt nur erreichbare Kandidaten
/// auf). Die bisherige Adresse ist nie ein Fund.
bool kandidatBestaetigt(PrinterConfig drucker, DruckerKandidat kandidat) {
  if (kandidat.host == drucker.host && kandidat.port == drucker.port) {
    return false;
  }
  final serial = drucker.serial;
  if (serial != null) {
    final serie = kandidat.serie;
    return serie != null && gleicheKennung(serial, serie);
  }
  return drucker.mac != null &&
      vergleicheMac(drucker.mac, kandidat.mac) == MacVergleich.gleich;
}

/// Der eine bestätigte Kandidat; `null` bei keinem oder bei mehreren
/// verschiedenen Adressen (dann wird nichts übernommen).
DruckerKandidat? einzigerKandidat(
  PrinterConfig drucker,
  Iterable<DruckerKandidat> kandidaten,
) {
  final bestaetigt = <String, DruckerKandidat>{};
  for (final kandidat in kandidaten) {
    if (kandidatBestaetigt(drucker, kandidat)) {
      bestaetigt.putIfAbsent(
        '${kandidat.host}:${kandidat.port}',
        () => kandidat,
      );
    }
  }
  return bestaetigt.length == 1 ? bestaetigt.values.single : null;
}

/// Findet einen Drucker unter einer neuen Adresse (Spec 1.3) und übernimmt
/// sie still: `config.json`, Logzeile, `relocations`, `printer.relocated`.
///
/// Je Drucker läuft höchstens eine Suche; wer währenddessen fragt, wartet auf
/// dasselbe Ergebnis. Abgeschaltet über `printer_relocate`.
class DruckerWiederfinder {
  DruckerWiederfinder({
    required this.registry,
    required ArpTabelle arp,
    required EscPosAbfrage abfrage,
    required PrinterDiscovery suche,
    required InterfaceProbe schnittstellen,
    PrintQueue? queue,
    EventBus? events,
    TcpProbe tcp = tcpReachable,
    bool Function()? zahlungLaeuft,
    AgentLog? log,
    DateTime Function()? clock,
    this.schnellBudget = schnellesWiederfindenBudget,
    this.scanBudget = defaultScanBudget,
  }) : _queue = queue,
       _arp = arp,
       _abfrage = abfrage,
       _suche = suche,
       _schnittstellen = schnittstellen,
       _events = events,
       _tcp = tcp,
       _zahlungLaeuft = zahlungLaeuft ?? _nie,
       _log = log,
       _clock = clock ?? DateTime.now;

  final PrinterRegistry registry;

  /// Warteschlangen der Drucker: Kandidaten unter der Adresse eines anderen
  /// eingerichteten Druckers fragt die gründliche Suche über dessen
  /// Warteschlange – nie neben einem seiner Bons.
  final PrintQueue? _queue;
  final ArpTabelle _arp;
  final EscPosAbfrage _abfrage;
  final PrinterDiscovery _suche;
  final InterfaceProbe _schnittstellen;
  final EventBus? _events;
  final TcpProbe _tcp;
  final bool Function() _zahlungLaeuft;
  final AgentLog? _log;
  final DateTime Function() _clock;

  final Duration schnellBudget;
  final Duration scanBudget;

  /// Laufende Suche je Drucker (single flight).
  final Map<String, Future<PrinterConfig?>> _laufend =
      <String, Future<PrinterConfig?>>{};

  /// Letzte gründliche Suche je Drucker.
  final Map<String, DateTime> _letzteGruendliche = <String, DateTime>{};

  /// Wie viele Suchen wirklich liefen (Tests: „genau eine“).
  int suchen = 0;

  static bool _nie() => false;

  /// Schnelles Wiederfinden (ARP, mDNS) für einen Auftrag; `null`, wenn es
  /// nicht genau einen bestätigten Treffer gibt. Läuft schon eine Suche, wird
  /// auf sie gewartet – höchstens [schnellBudget].
  Future<PrinterConfig?> schnell(PrinterConfig drucker) async {
    final laufend = _laufend[drucker.id];
    if (laufend != null) {
      return laufend.timeout(schnellBudget, onTimeout: () => null);
    }
    if (!await _erlaubt(drucker)) return null;
    // Während des Wartens kann eine Suche begonnen haben: dann auf sie.
    final inzwischen = _laufend[drucker.id];
    if (inzwischen != null) {
      return inzwischen.timeout(schnellBudget, onTimeout: () => null);
    }
    return _einmal(drucker.id, () => _schnellSuchen(drucker));
  }

  /// Stößt die gründliche Suche im Hintergrund an – höchstens einmal je
  /// [gruendlichAbstand] und nie während einer Zahlung.
  void gruendlichImHintergrund(String id) =>
      unawaited(gruendlich(id).then<void>((_) {}));

  /// Gründliche Suche (Netzscan); [erzwingen] übergeht den Abstand
  /// (`POST /v1/printers/{id}/locate`). `null` ohne eindeutigen Treffer.
  Future<PrinterConfig?> gruendlich(String id, {bool erzwingen = false}) async {
    final laufend = _laufend[id];
    if (laufend != null) return laufend;
    final drucker = await _finde(id);
    if (drucker == null || !await _erlaubt(drucker)) return null;
    // Während des Wartens kann eine Suche begonnen haben: dann auf sie, statt
    // am Abstand zu scheitern.
    final inzwischen = _laufend[id];
    if (inzwischen != null) return inzwischen;
    if (_zahlungLaeuft()) {
      _log?.info('Suche nach $id verschoben: eine Zahlung läuft.');
      return null;
    }
    final zuletzt = _letzteGruendliche[id];
    if (!erzwingen &&
        zuletzt != null &&
        _clock().difference(zuletzt) < gruendlichAbstand) {
      return null;
    }
    _letzteGruendliche[id] = _clock();
    return _einmal(id, () => _gruendlichSuchen(drucker));
  }

  Future<PrinterConfig?> _einmal(
    String id,
    Future<PrinterConfig?> Function() suche,
  ) {
    final laufend = _laufend[id];
    if (laufend != null) return laufend;
    suchen++;
    final arbeit = _sicher(id, suche).whenComplete(() {
      // Block statt Pfeil: `remove` liefert genau diese Zukunft, und
      // whenComplete wartete sonst auf sich selbst.
      _laufend.remove(id);
    });
    _laufend[id] = arbeit;
    return arbeit;
  }

  Future<PrinterConfig?> _sicher(
    String id,
    Future<PrinterConfig?> Function() suche,
  ) async {
    try {
      return await suche();
    } on Object catch (e) {
      // Ohne Fund bleibt es beim Verhalten von 1.4.2: Fehler an die Kasse.
      _log?.warn('Wiederfinden von $id gescheitert: $e');
      return null;
    }
  }

  Future<bool> _erlaubt(PrinterConfig drucker) async =>
      drucker.hatKennung &&
      (await registry.store.load()).aktiv(Neuerung.druckerWiederfinden);

  Future<PrinterConfig?> _finde(String id) async {
    for (final drucker in await registry.list()) {
      if (drucker.id == id) return drucker;
    }
    return null;
  }

  Future<PrinterConfig?> _schnellSuchen(PrinterConfig drucker) async {
    final uhr = Stopwatch()..start();
    Duration rest() {
      final r = schnellBudget - uhr.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    final kandidaten = <DruckerKandidat>[];
    // 1. ARP-Tabelle nach der gespeicherten MAC.
    if (drucker.mac != null) {
      final tabelle = await _arp.alle(frist: rest());
      for (final eintrag in tabelle.entries) {
        if (vergleicheMac(drucker.mac, eintrag.value) != MacVergleich.gleich) {
          continue;
        }
        final kandidat = await _pruefe(
          drucker,
          eintrag.key,
          eintrag.value,
          rest,
          imAuftrag: true,
        );
        if (kandidat != null) kandidaten.add(kandidat);
      }
    }
    // 2. mDNS mit TXT: Seriennummer, sonst Modell und MAC.
    if (einzigerKandidat(drucker, kandidaten) == null &&
        rest() > Duration.zero) {
      final funde = await _suche.discover().timeout(
        rest(),
        onTimeout: () => const DiscoveryResult(printers: []),
      );
      for (final fund in funde.printers) {
        if (fund.port != drucker.port || fund.host == drucker.host) continue;
        if (fund.serial != null) {
          kandidaten.add(
            DruckerKandidat(
              host: fund.host,
              port: fund.port,
              serie: fund.serial,
            ),
          );
        } else if (drucker.model != null &&
            fund.model != null &&
            gleicheKennung(drucker.model!, fund.model!)) {
          final mac = await macImSelbenNetz(
            fund.host,
            _arp,
            _schnittstellen,
            frist: rest(),
          );
          final kandidat = await _pruefe(
            drucker,
            fund.host,
            mac,
            rest,
            imAuftrag: true,
          );
          if (kandidat != null) kandidaten.add(kandidat);
        }
      }
    }
    return _uebernimmEinzigen(drucker, kandidaten, 'schnell');
  }

  Future<PrinterConfig?> _gruendlichSuchen(PrinterConfig drucker) async {
    final uhr = Stopwatch()..start();
    final netze = scanInterfaces(await _schnittstellen());
    final offen = <String>[];
    for (final netz in netze) {
      final left = scanBudget - uhr.elapsed;
      if (left <= Duration.zero) break;
      final treffer = await scanSubnet(
        hosts: subnetHosts(netz.address),
        port: drucker.port,
        budget: left,
        probe: _tcp,
      );
      offen.addAll(treffer.map((t) => t.host).where((h) => h != drucker.host));
    }
    // Nach dem Scan stehen frische Einträge in der ARP-Tabelle.
    final tabelle = await _arp.alle();
    final mitGleicherMac = offen
        .where(
          (h) => vergleicheMac(drucker.mac, tabelle[h]) == MacVergleich.gleich,
        )
        .toList();
    // Mit MAC zuerst die Treffer mit derselben MAC; sonst (oder ohne MAC)
    // alle offenen Adressen nach der Seriennummer fragen.
    final zuFragen = mitGleicherMac.isNotEmpty || drucker.serial == null
        ? mitGleicherMac
        : offen.take(gruendlichHoechstKandidaten).toList();
    final kandidaten = <DruckerKandidat>[];
    for (final host in zuFragen) {
      final kandidat = await _pruefe(
        drucker,
        host,
        tabelle[host],
        () => kandidatAbfrageBudget,
        imAuftrag: false,
      );
      if (kandidat != null) kandidaten.add(kandidat);
    }
    return _uebernimmEinzigen(drucker, kandidaten, 'gründlich');
  }

  /// Ein Kandidat unter [host]: mit gespeicherter Seriennummer nach `GS I 68`
  /// gefragt (nur 9100), sonst nur, wenn der Druckport antwortet.
  ///
  /// Gehört die Adresse einem anderen eingerichteten Drucker, fragt die
  /// gründliche Suche über dessen Warteschlange ([imAuftrag] `false`); die
  /// schnelle läuft selbst in einer Warteschlange und lässt solche Kandidaten
  /// aus – zwei Warteschlangen, die aufeinander warten, gäbe es so nie.
  Future<DruckerKandidat?> _pruefe(
    PrinterConfig drucker,
    String host,
    String? mac,
    Duration Function() rest, {
    required bool imAuftrag,
  }) async {
    if (rest() <= Duration.zero) return null;
    final anderer = await _andererDruckerUnter(host, drucker);
    if (anderer != null && (imAuftrag || _queue == null)) return null;
    if (drucker.serial != null) {
      if (drucker.kind != PrinterKind.tcp9100) return null;
      Future<EscPosAntworten> fragen() => _abfrage.frage(
        host,
        drucker.port,
        fragen: const <EscPosFrage>{EscPosFrage.seriennummer},
        budget: rest() < kandidatAbfrageBudget ? rest() : kandidatAbfrageBudget,
      );
      final antworten = anderer == null
          ? await fragen()
          : await _queue!.exclusive(anderer.id, fragen);
      return DruckerKandidat(
        host: host,
        port: drucker.port,
        mac: mac,
        serie: antworten.seriennummer,
      );
    }
    if (!await _tcp(host, drucker.port, _kurz(rest()))) return null;
    return DruckerKandidat(host: host, port: drucker.port, mac: mac);
  }

  /// Der eingerichtete Drucker (nicht [drucker]) unter [host]:Port von
  /// [drucker], sonst `null`.
  Future<PrinterConfig?> _andererDruckerUnter(
    String host,
    PrinterConfig drucker,
  ) async {
    for (final eintrag in await registry.list()) {
      if (eintrag.id != drucker.id &&
          eintrag.host == host &&
          eintrag.port == drucker.port) {
        return eintrag;
      }
    }
    return null;
  }

  static Duration _kurz(Duration rest) =>
      rest < defaultScanTimeout ? rest : defaultScanTimeout;

  Future<PrinterConfig?> _uebernimmEinzigen(
    PrinterConfig drucker,
    List<DruckerKandidat> kandidaten,
    String art,
  ) async {
    final bestaetigt = kandidaten.where((k) => kandidatBestaetigt(drucker, k));
    final fund = einzigerKandidat(drucker, kandidaten);
    if (fund == null) {
      if (bestaetigt.length > 1) {
        _log?.warn(
          'Drucker ${drucker.id}: ${bestaetigt.length} Geräte mit derselben '
          'Kennung gefunden – keins übernommen.',
        );
      } else {
        _log?.info('Drucker ${drucker.id}: Suche ($art) ohne Fund.');
      }
      return null;
    }
    return _uebernimm(drucker, fund);
  }

  Future<PrinterConfig?> _uebernimm(
    PrinterConfig drucker,
    DruckerKandidat fund,
  ) async {
    PrinterConfig? neu;
    final jetzt = _clock();
    await registry.store.mutate((config) {
      final printers = config.printers.toList();
      final index = printers.indexWhere((p) => p.id == drucker.id);
      if (index < 0) return config;
      final aktuell = printers[index];
      // Inzwischen anders eingerichtet (Kasse, zweite Suche): nichts ändern.
      if (aktuell.host != drucker.host || aktuell.port != drucker.port) {
        neu = aktuell;
        return config;
      }
      final umgezogen = aktuell.copyWith(host: fund.host);
      neu = umgezogen;
      printers[index] = umgezogen;
      return config
          .copyWith(printers: printers)
          .mitAdressWechsel(
            AdressWechsel(
              at: jetzt.toUtc(),
              art: GeraeteArt.drucker,
              kennung: drucker.id,
              von: '${drucker.host}:${drucker.port}',
              nach: '${fund.host}:${fund.port}',
            ),
          );
    });
    final ergebnis = neu;
    if (ergebnis == null || ergebnis.host != fund.host) return ergebnis;
    _arp.vergiss(drucker.host);
    registry.lagen.von(drucker.id)
      ..kennung = KennungsLage.bestaetigt
      ..kennungBestaetigtAm = jetzt
      ..konfliktSerie = null
      ..konfliktSucheBis = null
      ..stummBis = null;
    _log?.info(
      'Drucker ${drucker.id}: Adresse ${drucker.host} → ${fund.host}, '
      'Kennung bestätigt',
    );
    _events?.publish(eventPrinterRelocated, <String, Object?>{
      'printerId': drucker.id,
      'from': '${drucker.host}:${drucker.port}',
      'to': '${fund.host}:${fund.port}',
    });
    return ergebnis;
  }
}
