/// Not-Aus je Neuerung ab 1.5.0.
///
/// Jede Verhaltensänderung seit 1.4.2 lässt sich in der `config.json` einzeln
/// abschalten (`disabledFeatures`). Abgeschaltet verhält sich Connect an dieser
/// Stelle genau wie 1.4.2: keine zusätzlichen Bytes an Drucker, keine
/// Umleitung, kein Takt, keine Sperre. Vorgabe ist „alles an“.
///
/// Warum in der Datei und nicht als Umgebungsvariable: Der Support kann den
/// Schalter am Rechner des Kunden setzen, ohne den Autostart anzufassen, und
/// der laufende Agent sieht ihn bei der nächsten Anfrage (die Konfiguration
/// wird je Anfrage frisch gelesen).
library;

/// Eine abschaltbare Neuerung samt ihrem Namen in `disabledFeatures`.
enum Neuerung {
  /// Kennung der Drucker ermitteln und vor dem Druck prüfen (`GS I`, ARP).
  druckerKennung('printer_identity'),

  /// Papier und Deckel vor dem Druck abfragen (`DLE EOT`, ePOS-Status).
  druckerStatus('printer_status'),

  /// Drucker unter neuer Adresse wiederfinden.
  druckerWiederfinden('printer_relocate'),

  /// Terminal unter neuer Adresse wiederfinden und Aufrufe dorthin umleiten.
  terminalWiederfinden('terminal_relocate'),

  /// Drucker bei offener Kasse alle 60 s abfragen.
  statusTakt('status_poll'),

  /// Nach einem Bon an ein bewiesenes Modell abwarten, bis der Drucker die
  /// Verbindung beendet hat, bevor der nächste Auftrag an ihn geht.
  druckReihenfolge('print_order'),

  /// Ruhezustand des Rechners während laufender Vorgänge verhindern.
  schlafsperre('sleep_lock'),

  /// Update und Neustart während laufender Vorgänge sperren
  /// (`update_device_busy`, `restart_busy`, `betrieb.lock`).
  betriebSperre('busy_lock');

  const Neuerung(this.wireName);

  /// Name in `disabledFeatures` (englisch wie alle Namen der lokalen API).
  final String wireName;

  /// Die Neuerung zu einem Namen, `null` bei einem unbekannten.
  static Neuerung? fromWireName(String name) {
    for (final neuerung in values) {
      if (neuerung.wireName == name) return neuerung;
    }
    return null;
  }
}
