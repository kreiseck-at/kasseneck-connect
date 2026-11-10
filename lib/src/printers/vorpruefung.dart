import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../net/arp.dart';
import 'abfrage.dart';
import 'discovery.dart' show InterfaceProbe;
import 'driver.dart';
import 'erkennung.dart' show macImSelbenNetz;
import 'kennung.dart';
import 'lage.dart';
import 'registry.dart';
import 'zustand.dart';

/// Zeitbudget aller Prüfungen vor einem Bon (MAC, Abfrage-Verbindung).
///
/// Vorgabe des Inhabers: höchstens 600 ms Zuschlag je Druck. 500 ms lassen
/// Luft für das Einplanen; ein gesunder Drucker antwortet in Millisekunden,
/// das Budget zahlt nur ein Gerät, das schweigt – und das einmal je
/// `stummDauer`.
const Duration vorpruefungBudget = Duration(milliseconds: 500);

/// Zeitbudget der Prüfungen bei einem statusfähigen Drucker: zwei Versuche zu
/// je `bereitFrist` samt Verbindungsaufbau und Seriennummer. Ein bereiter
/// Drucker antwortet in Millisekunden; die 1,5 s zahlt nur einer, der schweigt
/// (Vorgabe nach dem Gerätetest: höchstens 1,5 s, nur in diesem Fehlerfall).
const Duration vorpruefungBudgetStatusfaehig = Duration(milliseconds: 1500);

/// Nach einem Kennungskonflikt ohne Fund sucht Connect so lange nicht erneut
/// vor jedem Bon (das schnelle Wiederfinden kostet bis zu 4 s). Ein getauschter
/// Drucker unter derselben Adresse druckt so wieder ohne Wartezeit.
const Duration konfliktSuchPause = Duration(minutes: 10);

/// Ergebnis der Prüfung vor dem Druck.
sealed class VorpruefungsErgebnis {
  const VorpruefungsErgebnis();
}

/// Drucken an [ziel] – die eingerichtete oder eine eben wiedergefundene
/// Adresse.
final class DruckFreigabe extends VorpruefungsErgebnis {
  const DruckFreigabe(this.ziel, {this.umgeleitet = false});

  final PrinterConfig ziel;

  /// Ob [ziel] eine neue Adresse ist (nach bewiesenem Konflikt gefunden).
  final bool umgeleitet;
}

/// Nicht drucken: es geht kein Byte hinaus.
final class DruckAbgelehnt extends VorpruefungsErgebnis {
  const DruckAbgelehnt(this.fehler);

  final PrinterFailure fehler;
}

/// Sucht einen Drucker schnell unter einer neuen Adresse (Spec 1.3, Schritt
/// 1); `null`, wenn es nicht genau einen bestätigten Treffer gibt.
typedef SchnellesWiederfinden =
    Future<PrinterConfig?> Function(PrinterConfig drucker);

/// Prüft vor jedem Bon, ob unter der Adresse derselbe Drucker hängt.
///
/// Was sie nicht sicher entscheiden kann, lässt den Druck gehen wie bis 1.4.2
/// (Grundsatz in `kennung.dart`). Die Druckverbindung selbst bleibt
/// unberührt: Fragen gehen über eine eigene Abfrage-Verbindung davor.
class DruckVorpruefung {
  DruckVorpruefung({
    required this.registry,
    required EscPosAbfrage abfrage,
    required ArpTabelle arp,
    required InterfaceProbe schnittstellen,
    this.schnellesWiederfinden,
    AgentLog? log,
    DateTime Function()? clock,
    this.budget = vorpruefungBudget,
    this.budgetStatusfaehig = vorpruefungBudgetStatusfaehig,
  }) : _abfrage = abfrage,
       _arp = arp,
       _schnittstellen = schnittstellen,
       _log = log,
       _clock = clock ?? DateTime.now;

  /// Drucker, Laufzeitstand und ePOS-Abruf.
  final PrinterRegistry registry;
  final EscPosAbfrage _abfrage;
  final ArpTabelle _arp;
  final InterfaceProbe _schnittstellen;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Schnelles Wiederfinden nach bewiesenem Konflikt (`null`: keins).
  SchnellesWiederfinden? schnellesWiederfinden;

  /// Zeitbudget der Prüfungen (ohne Wiederfinden).
  final Duration budget;

  /// Zeitbudget bei einem statusfähigen Drucker (zwei Versuche, wenn er
  /// schweigt).
  final Duration budgetStatusfaehig;

  ConfigStore get _store => registry.store;

  /// Prüft [drucker] vor einem Bon. Wirft nie.
  Future<VorpruefungsErgebnis> pruefe(
    PrinterConfig drucker,
    AgentConfig config,
  ) async {
    final kennungSchalter = config.aktiv(Neuerung.druckerKennung);
    final statusAn = config.aktiv(Neuerung.druckerStatus);
    if (!kennungSchalter && !statusAn) return DruckFreigabe(drucker);

    final uhr = Stopwatch()..start();
    final grenze = statusAn && drucker.statusCapableAt != null
        ? budgetStatusfaehig
        : budget;
    Duration rest() {
      final r = grenze - uhr.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    final jetzt = _clock();
    final lage = registry.lagen.von(drucker.id);
    final kennungAn = kennungSchalter && drucker.hatKennung;
    if (kennungSchalter && !drucker.hatKennung) {
      _hinweisEinmalJeTag(
        lage,
        jetzt,
        'Drucker ${drucker.id} hat noch keine Kennung – Druck ohne Prüfung.',
      );
    }

    // 1. MAC aus der ARP-Tabelle: kein Byte an den Drucker.
    var mac = MacVergleich.unbekannt;
    String? geseheneMac;
    if (kennungAn && drucker.mac != null) {
      geseheneMac = await macImSelbenNetz(
        drucker.host,
        _arp,
        _schnittstellen,
        frist: rest(),
      );
      mac = vergleicheMac(drucker.mac, geseheneMac);
    }
    final frisch = lage.frisch(jetzt);

    // 2. Eine Abfrage für Seriennummer und Status zusammen.
    String? geseheneSerie;
    DruckerZustand? zustand;
    switch (drucker.kind) {
      case PrinterKind.tcp9100:
        final fragSerie =
            kennungAn &&
            seriennummerFragen(
              gespeicherteSerie: drucker.serial,
              mac: mac,
              frisch: frisch,
            );
        final fragen = <EscPosFrage>{
          if (statusAn) EscPosFrage.rollensensor,
          if (fragSerie) EscPosFrage.seriennummer,
        };
        // Ein Drucker, der schon gültig geantwortet hat, wird immer gefragt:
        // schweigt er, ist er nicht bereit (Gerätetest TM-T20III).
        final statusfaehig = statusAn && drucker.statusCapableAt != null;
        if (statusfaehig) {
          final antworten = await _abfrage.frageBereit(
            drucker.host,
            drucker.port,
            fragen: fragen,
            budget: rest(),
          );
          geseheneSerie = antworten.seriennummer;
          if (antworten.stumm) {
            // Steht unter der Adresse nachweislich ein anderes Gerät (andere
            // MAC), sagt sein Schweigen nichts über den eingerichteten
            // Drucker – dann wie bis 1.4.2.
            zustand = mac == MacVergleich.anders
                ? null
                : DruckerZustand.nichtBereit;
          } else if (antworten.verbunden) {
            zustand = zustandAusDleEot(
              offlineGrund: antworten.offlineGrund,
              rollensensor: antworten.rollensensor,
            );
          }
        } else if (fragen.isNotEmpty && !lage.stumm(jetzt)) {
          final antworten = await _abfrage.frage(
            drucker.host,
            drucker.port,
            fragen: fragen,
            budget: rest(),
          );
          if (antworten.stumm) _alsStummMerken(drucker, lage, jetzt);
          geseheneSerie = antworten.seriennummer;
          if (antworten.offlineGrund != null) {
            unawaited(registry.statusfaehigMerken(drucker, jetzt));
          }
          if (statusAn && antworten.verbunden && !antworten.stumm) {
            zustand = zustandAusDleEot(
              offlineGrund: antworten.offlineGrund,
              rollensensor: antworten.rollensensor,
            );
          }
        }
      case PrinterKind.epos:
        if (statusAn) zustand = await registry.eposZustand(drucker, rest());
    }

    // 3. Kennung.
    if (kennungAn) {
      final befund = beurteileKennung(
        gespeicherteSerie: drucker.serial,
        mac: mac,
        geseheneSerie: geseheneSerie,
        frisch: frisch,
      );
      switch (befund) {
        case KennungsLage.bestaetigt:
          await _bestaetigt(
            drucker,
            lage,
            jetzt,
            mac,
            geseheneMac,
            geseheneSerie,
          );
        case KennungsLage.unbekannt:
          _hinweisEinmalJeTag(
            lage,
            jetzt,
            'Drucker ${drucker.id}: Kennung unter ${drucker.host}:'
            '${drucker.port} nicht prüfbar – Druck wie bisher.',
          );
        case KennungsLage.konflikt:
          // Papier und Deckel eines fremden Geräts zählen nicht.
          return _konflikt(drucker, config, lage, geseheneSerie!, jetzt);
      }
    }

    // 4. Papier und Deckel: blockiert wird nur, was das Gerät gemeldet hat.
    if (zustand != null) {
      registry.noteZustand(drucker.id, zustand, jetzt);
      final sperre = zustand.sperre;
      if (sperre != null) {
        _log?.warn(
          'Drucker ${drucker.id}: ${sperre.code} – kein Byte gesendet.',
        );
        return DruckAbgelehnt(sperre);
      }
    }
    return DruckFreigabe(drucker);
  }

  Future<void> _bestaetigt(
    PrinterConfig drucker,
    DruckerLage lage,
    DateTime jetzt,
    MacVergleich mac,
    String? geseheneMac,
    String? geseheneSerie,
  ) async {
    final warKonflikt = lage.kennung == KennungsLage.konflikt;
    lage
      ..kennung = KennungsLage.bestaetigt
      ..konfliktSerie = null
      ..konfliktSucheBis = null;
    if (geseheneSerie != null || mac == MacVergleich.gleich) {
      lage.kennungBestaetigtAm = jetzt;
    }
    if (warKonflikt) {
      _log?.info('Drucker ${drucker.id}: Kennung wieder bestätigt.');
    }
    if (mac == MacVergleich.anders && geseheneSerie != null) {
      await _neueMac(drucker, geseheneMac!);
    }
  }

  void _alsStummMerken(
    PrinterConfig drucker,
    DruckerLage lage,
    DateTime jetzt,
  ) {
    lage.alsStummMerken(jetzt);
    _log?.info(
      'Drucker ${drucker.id} antwortet nicht auf DLE EOT – '
      '${stummDauer.inMinutes} min ohne Abfrage.',
    );
  }

  /// Bewiesen ein anderer Drucker unter der Adresse: erst schnell suchen,
  /// sonst an die eingerichtete Adresse drucken wie bis 1.4.2. Die fremde
  /// Kennung wird nie übernommen.
  Future<VorpruefungsErgebnis> _konflikt(
    PrinterConfig drucker,
    AgentConfig config,
    DruckerLage lage,
    String geseheneSerie,
    DateTime jetzt,
  ) async {
    if (lage.kennung != KennungsLage.konflikt ||
        lage.konfliktSerie != geseheneSerie) {
      _log?.warn(
        'Drucker ${drucker.id}: unter ${drucker.host}:${drucker.port} '
        'antwortet ein anderer Drucker (Seriennummer $geseheneSerie statt '
        '${drucker.serial}).',
      );
    }
    lage
      ..kennung = KennungsLage.konflikt
      ..konfliktSerie = geseheneSerie;

    final suche = schnellesWiederfinden;
    final pause = lage.konfliktSucheBis;
    if (suche != null &&
        config.aktiv(Neuerung.druckerWiederfinden) &&
        (pause == null || !jetzt.isBefore(pause))) {
      final neu = await suche(drucker);
      if (neu != null) return DruckFreigabe(neu, umgeleitet: true);
      lage.konfliktSucheBis = jetzt.add(konfliktSuchPause);
    }
    _log?.info(
      'Drucker ${drucker.id}: Druck an die eingerichtete Adresse wie bisher '
      '(Kennungskonflikt).',
    );
    return DruckFreigabe(drucker);
  }

  /// Dieselbe Seriennummer unter einer anderen MAC: derselbe Drucker mit
  /// anderem Netzanschluss (etwa WLAN statt LAN) – die MAC wird nachgezogen,
  /// damit der nächste Bon ohne Frage geht.
  Future<void> _neueMac(PrinterConfig drucker, String mac) async {
    try {
      await _store.mutate((config) {
        final printers = config.printers.toList();
        final index = printers.indexWhere((p) => p.id == drucker.id);
        if (index < 0 || printers[index].host != drucker.host) return config;
        printers[index] = printers[index].copyWith(mac: mac);
        return config.copyWith(printers: printers);
      });
      _arp.vergiss(drucker.host);
      _log?.info(
        'Drucker ${drucker.id}: neue MAC $mac, Seriennummer bestätigt.',
      );
    } on Object catch (e) {
      // Ohne neue MAC fragt der nächste Bon wieder GS I – kein Schaden.
      _log?.warn('Drucker ${drucker.id}: MAC ließ sich nicht speichern: $e');
    }
  }

  void _hinweisEinmalJeTag(DruckerLage lage, DateTime jetzt, String text) {
    final tag = jetzt.toIso8601String().substring(0, 10);
    if (lage.letzterHinweisTag == tag) return;
    lage.letzterHinweisTag = tag;
    _log?.info(text);
  }
}
