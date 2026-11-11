import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import '../net/arp.dart';
import 'abfrage.dart';
import 'discovery.dart';
import 'kennung.dart';
import 'queue.dart';
import 'registry.dart';

/// Zeitbudget des schnellen Wiederfindens. Es läuft mitten in einem Auftrag
/// (nur bei einem bewiesenen Modell, dessen Abfrage keine Verbindung bekam)
/// und fragt nur die Adressen, unter denen die ARP-Tabelle seine MAC nennt,
/// nach der Seriennummer – meist eine, in Millisekunden.
const Duration schnellesWiederfindenBudget = Duration(seconds: 2);

/// Höchstens eine gründliche Suche je Drucker in diesem Abstand (Spec 1.3):
/// ein ausgeschalteter Drucker soll keinen Dauerscan auslösen.
const Duration gruendlichAbstand = Duration(minutes: 2);

/// Höchstens ein schnelles Wiederfinden je Drucker in diesem Abstand: zwei
/// Kassen, die an einen ausgeschalteten Drucker drucken, sollen nicht jede
/// für sich suchen. Die gründliche Suche im Hintergrund findet ihn trotzdem.
const Duration schnellAbstand = Duration(seconds: 60);

/// Zeit für die Seriennummer eines Kandidaten (eigene Abfrage-Verbindung).
const Duration kandidatAbfrageBudget = Duration(milliseconds: 800);

/// So viele Adressen fragt eine Suche höchstens nach der Seriennummer – mehr
/// Bondrucker hat kein Laden, und die Suche soll begrenzt bleiben.
const int gruendlichHoechstKandidaten = 32;

/// So lange wartet das Anhalten des Agenten höchstens auf laufende Suchen.
const Duration beendenHoechstens = Duration(seconds: 1);

/// Ereignis: ein Drucker ist still unter eine neue Adresse gezogen
/// (`{printerId, from, to}`). Für Log und Diagnose; die Kasse zeigt nichts.
const String eventPrinterRelocated = 'printer.relocated';

/// Ein Gerät unter einer anderen Adresse, das der gesuchte Drucker sein kann.
class DruckerKandidat {
  const DruckerKandidat({required this.host, required this.port, this.serie});

  final String host;
  final int port;

  /// Seriennummer, die das Gerät über `GS I 68` genannt hat.
  final String? serie;
}

/// Ob [kandidat] nachweislich [drucker] ist: dieselbe Seriennummer, über
/// `GS I 68` gelesen. Eine MAC beweist nichts (Repeater mit MAC-NAT nennen
/// für jedes Gerät dahinter dieselbe), ein offener Port auch nicht. Die
/// bisherige Adresse ist nie ein Fund.
bool kandidatBestaetigt(PrinterConfig drucker, DruckerKandidat kandidat) {
  if (kandidat.host == drucker.host && kandidat.port == drucker.port) {
    return false;
  }
  final serial = drucker.serial;
  final serie = kandidat.serie;
  return serial != null && serie != null && gleicheKennung(serial, serie);
}

/// Ob die Seriennummer von [drucker] ihn unter den eingerichteten Druckern
/// [alle] eindeutig bezeichnet. Ein Nachbau mit fest verdrahteter
/// Seriennummer trägt dieselbe wie ein anderer – dann ist jeder Fund
/// mehrdeutig, und übernommen wird nichts.
bool kennungEindeutig(PrinterConfig drucker, Iterable<PrinterConfig> alle) {
  final serial = drucker.serial;
  if (serial == null) return false;
  for (final anderer in alle) {
    if (anderer.id == drucker.id) continue;
    final serie = anderer.serial;
    if (serie != null && gleicheKennung(serial, serie)) return false;
  }
  return true;
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

  /// Letztes schnelles Wiederfinden je Drucker.
  final Map<String, DateTime> _letzteSchnelle = <String, DateTime>{};

  /// Wie viele Suchen wirklich liefen (Tests: „genau eine“).
  int suchen = 0;

  /// Wie viele davon schnelle waren.
  int schnelleSuchen = 0;

  /// Nach [beenden] beginnt keine Suche mehr, und keine übernimmt mehr eine
  /// Adresse.
  bool _beendet = false;

  /// Hält an: keine neuen Suchen, laufende übernehmen nichts mehr; wartet
  /// höchstens [beendenHoechstens] auf sie.
  Future<void> beenden() async {
    _beendet = true;
    try {
      await Future.wait(_laufend.values.toList()).timeout(beendenHoechstens);
    } on TimeoutException {
      // Eine Suche, die noch im Netz hängt, schreibt nach dem Ende nichts
      // mehr (siehe _uebernimm); warten lohnt nicht länger.
    }
  }

  static bool _nie() => false;

  /// Schnelles Wiederfinden (ARP, mDNS) für einen Auftrag; `null`, wenn es
  /// nicht genau einen bestätigten Treffer gibt. Läuft schon eine Suche, wird
  /// auf sie gewartet – höchstens [schnellBudget]. Höchstens einmal je
  /// [schnellAbstand].
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
    final zuletzt = _letzteSchnelle[drucker.id];
    final jetzt = _clock();
    if (zuletzt != null) {
      final alter = jetzt.difference(zuletzt);
      if (!alter.isNegative && alter < schnellAbstand) return null;
    }
    _letzteSchnelle[drucker.id] = jetzt;
    schnelleSuchen++;
    return _einmal(drucker.id, () => _schnellSuchen(drucker));
  }

  /// Stößt die gründliche Suche im Hintergrund an – höchstens einmal je
  /// [gruendlichAbstand] und nie während einer Zahlung.
  void gruendlichImHintergrund(String id) =>
      unawaited(gruendlich(id).then<void>((_) {}));

  /// Gründliche Suche (Netzscan); [erzwingen] übergeht den Abstand
  /// (`POST /v1/printers/{id}/locate`). `null` ohne eindeutigen Treffer.
  Future<PrinterConfig?> gruendlich(String id, {bool erzwingen = false}) async {
    final arbeit = await _gruendlichStarten(id, erzwingen: erzwingen);
    return arbeit == null ? null : await arbeit;
  }

  /// Wie [gruendlich] mit Abstand übergangen, sagt aber auch, ob überhaupt
  /// gesucht wurde (nicht: abgeschaltet, Zahlung, angehalten, keine
  /// Seriennummer). Für die Übernahme einer neuen Kennung: der alte Drucker
  /// gilt erst als „nirgends zu finden“, wenn wirklich gesucht wurde.
  Future<({bool gesucht, PrinterConfig? fund})> gruendlichMitAuskunft(
    String id,
  ) async {
    final arbeit = await _gruendlichStarten(id, erzwingen: true);
    if (arbeit == null) return (gesucht: false, fund: null);
    return (gesucht: true, fund: await arbeit);
  }

  /// Die laufende oder eben begonnene gründliche Suche; `null`, wenn keine
  /// beginnt.
  Future<Future<PrinterConfig?>?> _gruendlichStarten(
    String id, {
    required bool erzwingen,
  }) async {
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
    // Die gründliche Suche schickt Bytes nur an Geräte desselben Herstellers
    // (siehe _gruendlichSuchen); ohne gemerkte MAC wüsste sie nicht, welche –
    // dann sucht sie gar nicht (und der alte Drucker gilt nicht als
    // „nirgends zu finden“).
    if (macHersteller(drucker.mac) == null) {
      _log?.info(
        'Drucker $id: keine gemerkte MAC – keine gründliche Suche (Bytes '
        'nur an Geräte desselben Herstellers).',
      );
      return null;
    }
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

  /// Gesucht wird nur ein 9100-Drucker mit Seriennummer: nur sie beweist
  /// den Fund. Ohne lesbare Seriennummer bleibt es wie bis 1.4.2.
  Future<bool> _erlaubt(PrinterConfig drucker) async =>
      !_beendet &&
      drucker.kind == PrinterKind.tcp9100 &&
      drucker.serial != null &&
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

    if (drucker.mac == null || !await _eindeutig(drucker)) return null;
    // Die ARP-Tabelle zeigt, wo die MAC jetzt steht – nur ein Hinweis, wo
    // `GS I 68` gefragt wird. Kein Netzverkehr außer zu diesen Adressen.
    final tabelle = await _arp.alle(frist: rest());
    final kandidaten = <DruckerKandidat>[];
    for (final host in _hinweise(drucker, tabelle)) {
      final kandidat = await _pruefe(drucker, host, rest, imAuftrag: true);
      if (kandidat != null) kandidaten.add(kandidat);
    }
    return _uebernimmEinzigen(drucker, kandidaten, 'schnell');
  }

  /// Netzscan (nur Verbindungsaufbau, kein Byte), dann `DLE EOT` und
  /// `GS I 68` – aber nur an Adressen, deren MAC in der ARP-Tabelle dieselbe
  /// Herstellerkennung (OUI) trägt wie die gemerkte des Druckers. Ein Büro-
  /// oder Etikettendrucker auf 9100 bekam bis 1.4.2 nie ein Byte von
  /// Connect; ein Laser im Raw-Modus druckte daraus womöglich eine Seite.
  Future<PrinterConfig?> _gruendlichSuchen(PrinterConfig drucker) async {
    if (!await _eindeutig(drucker)) return null;
    final hersteller = macHersteller(drucker.mac);
    if (hersteller == null) return null;
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
    // Nach dem Scan stehen frische Einträge in der ARP-Tabelle: Adressen mit
    // derselben MAC zuerst gefragt, dann die übrigen offenen desselben
    // Herstellers. Ohne Eintrag (kein ARP, anderes Netz) kein Byte.
    final tabelle = await _arp.alle();
    final gleicherHersteller = offen
        .where((h) => macHersteller(tabelle[h]) == hersteller)
        .toList();
    final zuerst = _hinweise(
      drucker,
      tabelle,
    ).where(gleicherHersteller.contains).toList();
    final zuFragen = <String>[
      ...zuerst,
      ...gleicherHersteller.where((h) => !zuerst.contains(h)),
    ].take(gruendlichHoechstKandidaten);
    final kandidaten = <DruckerKandidat>[];
    for (final host in zuFragen) {
      final kandidat = await _pruefe(
        drucker,
        host,
        () => kandidatAbfrageBudget,
        imAuftrag: false,
      );
      if (kandidat != null) kandidaten.add(kandidat);
    }
    return _uebernimmEinzigen(drucker, kandidaten, 'gründlich');
  }

  /// Ob die Seriennummer von [drucker] unter den eingerichteten Druckern
  /// eindeutig ist ([kennungEindeutig]); sonst eine Logzeile und keine Suche.
  Future<bool> _eindeutig(PrinterConfig drucker) async {
    if (kennungEindeutig(drucker, await registry.list())) return true;
    _log?.warn(
      'Drucker ${drucker.id}: ein anderer eingerichteter Drucker trägt '
      'dieselbe Seriennummer – Connect sucht ihn nicht unter neuer Adresse.',
    );
    return false;
  }

  /// Adressen außer der bisherigen, unter denen die MAC von [drucker] in
  /// [tabelle] steht – höchstens [gruendlichHoechstKandidaten].
  List<String> _hinweise(PrinterConfig drucker, Map<String, String> tabelle) =>
      adressenMitMac(tabelle, drucker.mac)
          .where((h) => h != drucker.host)
          .take(gruendlichHoechstKandidaten)
          .toList();

  /// Ein Kandidat unter [host]: nach `GS I 68` gefragt.
  ///
  /// Gehört die Adresse einem anderen eingerichteten Drucker, fragt die
  /// gründliche Suche über dessen Warteschlange ([imAuftrag] `false`); die
  /// schnelle läuft selbst in einer Warteschlange und lässt solche Kandidaten
  /// aus – zwei Warteschlangen, die aufeinander warten, gäbe es so nie.
  Future<DruckerKandidat?> _pruefe(
    PrinterConfig drucker,
    String host,
    Duration Function() rest, {
    required bool imAuftrag,
  }) async {
    if (rest() <= Duration.zero) return null;
    final anderer = await _andererDruckerUnter(host, drucker);
    if (anderer != null && (imAuftrag || _queue == null)) return null;
    Future<EscPosAntworten> fragen() => _abfrage.frage(
      host,
      drucker.port,
      fragen: const <EscPosFrage>{EscPosFrage.seriennummer},
      budget: rest() < kandidatAbfrageBudget ? rest() : kandidatAbfrageBudget,
    );
    final antworten = anderer == null
        ? await fragen()
        : await _queue!.exclusive(anderer.id, () async {
            final a = await fragen();
            // Ein Bon an den anderen Drucker direkt danach wartet auf die
            // Freigabe dieser Verbindung (DruckerLage.ebenAbgefragt).
            if (a.verbunden) registry.lagen.von(anderer.id).abgefragt();
            return a;
          });
    final kandidat = DruckerKandidat(
      host: host,
      port: drucker.port,
      serie: antworten.seriennummer,
    );
    // Der gesuchte Drucker selbst: ein Bon an die neue Adresse direkt danach
    // wartet ebenso auf die Freigabe.
    if (antworten.verbunden && kandidatBestaetigt(drucker, kandidat)) {
      registry.lagen.von(drucker.id).abgefragt();
    }
    return kandidat;
  }

  /// Der eingerichtete Drucker (nicht [drucker]) unter [host]:Port von
  /// [drucker], sonst `null`.
  Future<PrinterConfig?> _andererDruckerUnter(
    String host,
    PrinterConfig drucker,
  ) async {
    // Ohne Groß-/Kleinschreibung wie beim Umzug (_uebernimm): sonst ginge
    // die Abfrage an `Drucker.local` neben dessen Warteschlange vorbei.
    final gesucht = host.toLowerCase();
    for (final eintrag in await registry.list()) {
      if (eintrag.id != drucker.id &&
          eintrag.host.toLowerCase() == gesucht &&
          eintrag.port == drucker.port) {
        return eintrag;
      }
    }
    return null;
  }

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
    if (_beendet) return null;
    PrinterConfig? neu;
    var doppelt = false;
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
      // Unter der neuen Adresse steht schon ein anderer eingerichteter
      // Drucker: zwei Einträge auf ein Gerät hießen jeden Bon doppelt (wie
      // 1.4.2 beim Anlegen, siehe PrinterRegistry.upsert). Nichts ändern.
      final belegt = printers.any(
        (p) =>
            p.id != drucker.id &&
            p.host.toLowerCase() == fund.host.toLowerCase() &&
            p.port == fund.port,
      );
      if (belegt) {
        doppelt = true;
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
    if (doppelt) {
      _log?.warn(
        'Drucker ${drucker.id}: unter ${fund.host}:${fund.port} ist schon ein '
        'anderer Drucker eingerichtet – Adresse nicht übernommen.',
      );
      return null;
    }
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
