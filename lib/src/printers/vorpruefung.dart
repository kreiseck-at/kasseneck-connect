import 'dart:async';

import '../config/model.dart';
import '../config/neuerungen.dart';
import '../config/store.dart';
import '../log/logger.dart';
import '../lokales_netz.dart' show verbindungAbgelehnt;
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
/// vor jedem Bon. Ein getauschter Drucker unter derselben Adresse druckt so
/// wieder ohne Wartezeit.
const Duration konfliktSuchPause = Duration(minutes: 10);

/// So oft vor einem Bon und …
const int ersetzenNachBons = 3;

/// … über mindestens diese Zeit muss unter der eingerichteten Adresse
/// dieselbe fremde Seriennummer antworten, bevor Connect die Kennung
/// übernimmt (wenn der alte Drucker nirgends zu finden ist). Ein Drucker, der
/// nur kurz vertreten wird, behält so seine Kennung.
const Duration ersetzenNachDauer = Duration(hours: 1);

/// Wird gerufen, wenn unter der Adresse von [drucker] dauerhaft ein anderer
/// Drucker mit [neueSerie] antwortet. Darf nicht warten lassen und nicht
/// werfen.
typedef DauerhafterKonflikt =
    void Function(PrinterConfig drucker, String neueSerie);

/// Ergebnis der Prüfung vor dem Druck.
sealed class VorpruefungsErgebnis {
  const VorpruefungsErgebnis();
}

/// Was die Abfrage-Verbindung vor dem Druck erlebte.
enum AbfrageVerlauf {
  /// Keine Abfrage-Verbindung (abgeschaltet, als stumm gemerkt, ePOS).
  keine,

  /// Der Drucker war eben unter der Adresse erreichbar: die Abfrage-Verbindung
  /// stand, oder sie kam nicht zustande, während der eigene Bon dort noch
  /// druckt. Lehnt er die Druckverbindung ab, gibt er nur die vorige noch
  /// nicht frei – umgezogen ist er nicht.
  ebenErreichbar,

  /// Ein statusfähiger Drucker lehnte sie ab, obwohl dieser Rechner in den
  /// letzten [kontaktFenster] mit ihm verbunden war: er ist da und gerade
  /// belegt, etwa von der Nachfrage eines anderen Rechners. Die Warteschlange
  /// wiederholt die Druckverbindung wie bei [ebenErreichbar], merkt ihn aber
  /// nicht als „gibt langsam frei“.
  kurzBelegt,

  /// Sie kam nicht zustande. Das zählt als erster Druckversuch – sonst
  /// dauerte ein ausgeschalteter Drucker länger als bis 1.4.2.
  ohneVerbindung,
}

/// Drucken an [ziel] – die eingerichtete oder eine eben wiedergefundene
/// Adresse.
final class DruckFreigabe extends VorpruefungsErgebnis {
  const DruckFreigabe(
    this.ziel, {
    this.umgeleitet = false,
    this.abfrage = AbfrageVerlauf.keine,
  });

  final PrinterConfig ziel;

  /// Ob [ziel] eine neue Adresse ist (nach bewiesenem Konflikt gefunden).
  final bool umgeleitet;

  /// Was die Abfrage-Verbindung an [ziel] erlebte.
  final AbfrageVerlauf abfrage;
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

  /// Übernahme der Kennung nach einem dauerhaften Konflikt (`null`: keine).
  DauerhafterKonflikt? beiDauerhaftemKonflikt;

  /// Wird mit der Drucker-ID gerufen, wenn ein statusfähiger Drucker vor
  /// einem Bon nachweislich schweigt (der Statusdienst fragt dann in kurzen
  /// Abständen nach, siehe [schweigenNachfrageAbstand]). Darf nicht warten
  /// lassen und nicht werfen.
  void Function(String printerId)? beiSchweigen;

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
    // Nur ein im Gerätetest bewiesenes Modell wird vor dem Bon gefragt; jeder
    // andere Drucker druckt exakt wie bis 1.4.2 – keine Verbindung, kein ARP.
    if (!registry.pruefbar(drucker)) return DruckFreigabe(drucker);

    final statusfaehig = statusAn && drucker.statusCapableAt != null;
    final uhr = Stopwatch()..start();
    final grenze = statusfaehig ? budgetStatusfaehig : budget;
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

    // 1. MAC aus der ARP-Tabelle: kein Byte an den Drucker. Sie dient der
    // Kennung und entscheidet mit, ob Schweigen „nicht bereit“ heißen darf.
    var mac = MacVergleich.unbekannt;
    String? geseheneMac;
    if (drucker.mac != null && (kennungAn || statusfaehig)) {
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
    var abfrage = AbfrageVerlauf.keine;
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
        // Der eigene vorige Bon druckt noch: der Drucker war eben da, und
        // eine Abfrage bewiese nichts (er antwortet währenddessen erst
        // verzögert) – sie kostete nur Zeit. Wie der Statustakt: keine.
        final eigenerBonDruckt = lage.druckt(jetzt);
        EscPosAntworten? antworten;
        if (eigenerBonDruckt) {
          antworten = null;
        } else if (statusfaehig) {
          // Ein Drucker, der schon gültig geantwortet hat, wird immer
          // gefragt: schweigt er, ist er womöglich nicht bereit (Gerätetest
          // TM-T20III).
          antworten = await _abfrage.frageBereit(
            drucker.host,
            drucker.port,
            fragen: fragen,
            budget: rest(),
          );
        } else if (fragen.isNotEmpty && !lage.stumm(jetzt)) {
          antworten = await _abfrage.frage(
            drucker.host,
            drucker.port,
            fragen: fragen,
            budget: rest(),
          );
        }
        if (antworten != null) {
          if (antworten.verbunden) lage.abgefragt();
          // Abgelehnt, obwohl eben noch eine eigene Verbindung stand (Bon,
          // Takt): der Drucker gibt sie nur langsam frei – er ist da.
          final ebenDa =
              !antworten.verbunden &&
              antworten.verbindungsFehler != null &&
              (lage.druckt(jetzt) || lage.ebenVerbunden());
          if (ebenDa) _langsameFreigabe(drucker, lage);
          // Abgelehnt kurz nach eigenem Kontakt: belegt, nicht aus (mehrere
          // Kassen, ein Drucker – die Nachfrage eines anderen Rechners).
          final belegt =
              !antworten.verbunden &&
              !ebenDa &&
              statusfaehig &&
              verbindungAbgelehnt(antworten.verbindungsFehler) &&
              lage.kuerzlichVerbunden();
          abfrage = antworten.verbunden || ebenDa
              ? AbfrageVerlauf.ebenErreichbar
              : belegt
              ? AbfrageVerlauf.kurzBelegt
              : antworten.verbindungsFehler != null
              ? AbfrageVerlauf.ohneVerbindung
              : AbfrageVerlauf.keine;
          geseheneSerie = antworten.seriennummer;
          zustand = _deute(
            drucker,
            antworten,
            lage,
            jetzt,
            mac: mac,
            statusAn: statusAn,
          );
        }
      case PrinterKind.epos:
        // Nie bewiesen (siehe registry.pruefbar): hierher kommt keiner.
        break;
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
          _bestaetigt(drucker, lage, jetzt, mac, geseheneMac, geseheneSerie);
        case KennungsLage.unbekannt:
          _hinweisEinmalJeTag(
            lage,
            jetzt,
            'Drucker ${drucker.id}: Kennung unter ${drucker.host}:'
            '${drucker.port} nicht prüfbar – Druck wie bisher.',
          );
        case KennungsLage.konflikt:
          final neu = await _konflikt(
            drucker,
            config,
            lage,
            geseheneSerie!,
            jetzt,
          );
          if (neu != null) return neu;
        // Ohne Fund geht der Bon an die eingerichtete Adresse wie bis 1.4.2 –
        // dann zählen Papier und Deckel des Geräts, das ihn dort bekommt.
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
    return DruckFreigabe(drucker, abfrage: abfrage);
  }

  /// Papier, Deckel und Bereitschaft aus den Antworten einer 9100-Abfrage;
  /// `null`, wenn sich am bekannten Stand nichts ändern soll.
  DruckerZustand? _deute(
    PrinterConfig drucker,
    EscPosAntworten antworten,
    DruckerLage lage,
    DateTime jetzt, {
    required MacVergleich mac,
    required bool statusAn,
  }) {
    if (!antworten.verbunden) return null;
    if (antworten.stumm) {
      if (!statusAn || drucker.statusCapableAt == null) {
        // Nie gültig geantwortet: ein Gerät ohne Echtzeitstatus. Ein Bon,
        // der noch druckt, ist dafür kein Beweis.
        if (!lage.druckt(jetzt)) _alsStummMerken(drucker, lage, jetzt);
        return null;
      }
      // Schweigen während eines eigenen Bons beweist nichts; sonst beginnt
      // (oder läuft) die Strecke, nach der es „nicht bereit“ heißt – und der
      // Statusdienst beobachtet sie lückenlos weiter.
      if (!lage.druckt(jetzt)) {
        lage.schweigt(jetzt);
        // Nachgefragt wird nur bei einem Gerät, das nicht nachweislich ein
        // anderes ist: ein fremdes Gerät bekommt keine Bytes.
        if (mac != MacVergleich.anders) beiSchweigen?.call(drucker.id);
      }
      return schweigenHeisstNichtBereit(mac: mac, lage: lage, jetzt: jetzt)
          ? DruckerZustand.nichtBereit
          : DruckerZustand.unbekannt;
    }
    if (antworten.offlineGrund == null) {
      // Gefragt, aber nicht entscheidbar (zu wenig Zeit, langsamer Aufbau,
      // Gegenstelle schloss): unbekannt, gedruckt wird wie bis 1.4.2.
      return statusAn ? DruckerZustand.unbekannt : null;
    }
    lage.antwortet();
    // Antwortet unter der Adresse nachweislich ein anderes Gerät (andere MAC),
    // sagt das nichts über den eingerichteten Drucker.
    if (mac != MacVergleich.anders) registry.statusfaehigMerken(drucker, jetzt);
    return statusAn
        ? zustandAusDleEot(
            offlineGrund: antworten.offlineGrund,
            rollensensor: antworten.rollensensor,
          )
        : null;
  }

  void _bestaetigt(
    PrinterConfig drucker,
    DruckerLage lage,
    DateTime jetzt,
    MacVergleich mac,
    String? geseheneMac,
    String? geseheneSerie,
  ) {
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
      _neueMac(drucker, geseheneMac!);
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

  /// Bewiesen ein anderer Drucker unter der Adresse: erst schnell suchen;
  /// ohne Fund `null` – dann geht der Bon an die eingerichtete Adresse wie bis
  /// 1.4.2. Die fremde Kennung wird nie übernommen (aufgelöst wird der
  /// Konflikt durch eine Neueinrichtung, siehe [PrinterRegistry.upsert]).
  Future<DruckFreigabe?> _konflikt(
    PrinterConfig drucker,
    AgentConfig config,
    DruckerLage lage,
    String geseheneSerie,
    DateTime jetzt,
  ) async {
    if (lage.kennung != KennungsLage.konflikt ||
        lage.konfliktSerie == null ||
        !gleicheKennung(lage.konfliktSerie!, geseheneSerie)) {
      _log?.warn(
        'Drucker ${drucker.id}: unter ${drucker.host}:${drucker.port} '
        'antwortet ein anderer Drucker (Seriennummer $geseheneSerie statt '
        '${drucker.serial}).',
      );
      lage
        ..konfliktSeit = jetzt
        ..konfliktBons = 0
        ..ersetzenAngestossen = false;
    }
    lage
      ..kennung = KennungsLage.konflikt
      ..konfliktSerie = geseheneSerie
      ..konfliktBons += 1;

    final suche = schnellesWiederfinden;
    final pause = lage.konfliktSucheBis;
    if (suche != null &&
        config.aktiv(Neuerung.druckerWiederfinden) &&
        (pause == null || !jetzt.isBefore(pause))) {
      final neu = await suche(drucker);
      if (neu != null) return DruckFreigabe(neu, umgeleitet: true);
      lage.konfliktSucheBis = jetzt.add(konfliktSuchPause);
    }
    final seit = lage.konfliktSeit;
    final ersetzen = beiDauerhaftemKonflikt;
    if (ersetzen != null &&
        !lage.ersetzenAngestossen &&
        lage.konfliktBons >= ersetzenNachBons &&
        seit != null &&
        jetzt.difference(seit) >= ersetzenNachDauer) {
      lage.ersetzenAngestossen = true;
      ersetzen(drucker, geseheneSerie);
    }
    _log?.info(
      'Drucker ${drucker.id}: Druck an die eingerichtete Adresse wie bisher '
      '(Kennungskonflikt).',
    );
    return null;
  }

  void _langsameFreigabe(PrinterConfig drucker, DruckerLage lage) {
    if (lage.gibtLangsamFrei) return;
    lage.gibtLangsamFrei = true;
    _log?.info(
      'Drucker ${drucker.id} gibt seine Verbindung erst verzögert frei – '
      'ab jetzt keine Prüfung mehr vor dem Bon (Druck wie bisher).',
    );
  }

  /// Dieselbe Seriennummer unter einer anderen MAC: derselbe Drucker mit
  /// anderem Netzanschluss (etwa WLAN statt LAN) – die MAC wird im
  /// Hintergrund nachgezogen, damit der nächste Bon ohne Frage geht. Nicht,
  /// wenn sie in der ARP-Tabelle auch unter einer anderen Adresse steht
  /// (Repeater mit MAC-NAT): dann kennzeichnet sie kein Gerät.
  void _neueMac(PrinterConfig drucker, String mac) {
    registry.imHintergrund('Drucker ${drucker.id}: neue MAC', () async {
      final tabelle = await _arp.alle();
      if (adressenMitMac(tabelle, mac).any((h) => h != drucker.host)) {
        _log?.info(
          'Drucker ${drucker.id}: MAC $mac steht auch unter einer anderen '
          'Adresse – nicht übernommen.',
        );
        return;
      }
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
    });
  }

  void _hinweisEinmalJeTag(DruckerLage lage, DateTime jetzt, String text) {
    final tag = jetzt.toIso8601String().substring(0, 10);
    if (lage.letzterHinweisTag == tag) return;
    lage.letzterHinweisTag = tag;
    _log?.info(text);
  }
}
