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

/// Zeitbudget aller Prüfungen vor einem Bon (MAC, Abfrage-Verbindung).
///
/// Vorgabe des Inhabers: höchstens 600 ms Zuschlag je Druck. 500 ms lassen
/// Luft für das Einplanen; ein gesunder Drucker antwortet in Millisekunden,
/// das Budget zahlt nur ein Gerät, das schweigt – und das einmal je
/// [stummDauer].
const Duration vorpruefungBudget = Duration(milliseconds: 500);

/// So lange gilt ein Gerät nach einer Abfrage ohne gültige Antwort als stumm:
/// vor seinen Bons geht keine Abfrage-Verbindung hinaus, gedruckt wird ohne
/// Zuschlag wie bis 1.4.2. Zehn Minuten, damit ein Drucker, der nur kurz
/// beschäftigt war, bald wieder geprüft wird.
const Duration stummDauer = Duration(minutes: 10);

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
    required this.store,
    required EscPosAbfrage abfrage,
    required ArpTabelle arp,
    required InterfaceProbe schnittstellen,
    required this.lagen,
    this.schnellesWiederfinden,
    AgentLog? log,
    DateTime Function()? clock,
    this.budget = vorpruefungBudget,
  }) : _abfrage = abfrage,
       _arp = arp,
       _schnittstellen = schnittstellen,
       _log = log,
       _clock = clock ?? DateTime.now;

  final ConfigStore store;
  final EscPosAbfrage _abfrage;
  final ArpTabelle _arp;
  final InterfaceProbe _schnittstellen;
  final DruckerLagen lagen;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Schnelles Wiederfinden nach bewiesenem Konflikt (`null`: keins).
  SchnellesWiederfinden? schnellesWiederfinden;

  /// Zeitbudget der Prüfungen (ohne Wiederfinden).
  final Duration budget;

  /// Prüft [drucker] vor einem Bon. Wirft nie.
  Future<VorpruefungsErgebnis> pruefe(
    PrinterConfig drucker,
    AgentConfig config,
  ) async {
    final kennungAn = config.aktiv(Neuerung.druckerKennung);
    if (!kennungAn) return DruckFreigabe(drucker);

    final uhr = Stopwatch()..start();
    Duration rest() {
      final r = budget - uhr.elapsed;
      return r.isNegative ? Duration.zero : r;
    }

    final jetzt = _clock();
    final lage = lagen.von(drucker.id);
    if (!drucker.hatKennung) {
      _hinweisEinmalJeTag(
        lage,
        jetzt,
        'Drucker ${drucker.id} hat noch keine Kennung – Druck ohne Prüfung.',
      );
      return DruckFreigabe(drucker);
    }

    var mac = MacVergleich.unbekannt;
    String? geseheneMac;
    if (drucker.mac != null) {
      geseheneMac = await macImSelbenNetz(
        drucker.host,
        _arp,
        _schnittstellen,
        frist: rest(),
      );
      mac = vergleicheMac(drucker.mac, geseheneMac);
    }

    final frisch = lage.frisch(jetzt);
    final fragen =
        drucker.kind == PrinterKind.tcp9100 &&
        !lage.stumm(jetzt) &&
        seriennummerFragen(
          gespeicherteSerie: drucker.serial,
          mac: mac,
          frisch: frisch,
        );
    String? geseheneSerie;
    if (fragen) {
      final antworten = await _abfrage.frage(
        drucker.host,
        drucker.port,
        fragen: const <EscPosFrage>{EscPosFrage.seriennummer},
        budget: rest(),
      );
      if (antworten.stumm) {
        lage.stummBis = jetzt.add(stummDauer);
        _log?.info(
          'Drucker ${drucker.id} antwortet nicht auf DLE EOT – '
          '${stummDauer.inMinutes} min ohne Abfrage.',
        );
      }
      geseheneSerie = antworten.seriennummer;
    }

    final befund = beurteileKennung(
      gespeicherteSerie: drucker.serial,
      mac: mac,
      geseheneSerie: geseheneSerie,
      frisch: frisch,
    );
    switch (befund) {
      case KennungsLage.bestaetigt:
        final warKonflikt = lage.kennung == KennungsLage.konflikt;
        lage
          ..kennung = KennungsLage.bestaetigt
          ..konfliktSerie = null
          ..konfliktSucheBis = null;
        if (geseheneSerie != null) lage.kennungBestaetigtAm = jetzt;
        if (mac == MacVergleich.gleich) lage.kennungBestaetigtAm = jetzt;
        if (warKonflikt) {
          _log?.info('Drucker ${drucker.id}: Kennung wieder bestätigt.');
        }
        if (mac == MacVergleich.anders && geseheneSerie != null) {
          await _neueMac(drucker, geseheneMac!);
        }
        return DruckFreigabe(drucker);
      case KennungsLage.unbekannt:
        _hinweisEinmalJeTag(
          lage,
          jetzt,
          'Drucker ${drucker.id}: Kennung unter ${drucker.host}:'
          '${drucker.port} nicht prüfbar – Druck wie bisher.',
        );
        return DruckFreigabe(drucker);
      case KennungsLage.konflikt:
        return _konflikt(drucker, config, lage, geseheneSerie!, jetzt);
    }
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
      await store.mutate((config) {
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
