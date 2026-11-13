import 'dart:typed_data';

/// Drucker-ID ist nicht bekannt.
const String errorPrinterUnknown = 'printer_unknown';

/// Drucker antwortet nicht (Verbindung, Netz, Gerät aus).
const String errorPrinterOffline = 'printer_offline';

/// Der Drucker hat nicht rechtzeitig geantwortet.
const String errorPrintTimeout = 'timeout';

/// Der Drucker hat den Auftrag abgelehnt (ePOS `success="false"`, z. B. Papier
/// leer oder Deckel offen).
const String errorPrintRefused = 'refused';

/// Papierende vor dem Druck: kein Byte ging hinaus (ab 1.5.0,
/// `printer_status`).
const String errorPaperOut = 'paper_out';

/// Deckel offen vor dem Druck: kein Byte ging hinaus (ab 1.5.0,
/// `printer_status`).
const String errorCoverOpen = 'cover_open';

/// Der Drucker meldet selbst, dass er nicht bereit ist (Antwort auf
/// `DLE EOT`). Kein Byte ging hinaus (ab 1.5.0). Schweigen ergibt ihn nie:
/// ein Drucker, der schweigt, bedient womöglich gerade einen anderen Rechner
/// (Gerätetest 12.11.2026) – dann wird gedruckt wie bis 1.4.2.
const String errorPrinterNotReady = 'printer_not_ready';

/// Derselbe `jobId` läuft noch.
const String errorPrintInProgress = 'print_in_progress';

/// Der Agent selbst ist gestolpert (Fehler außerhalb des Treibers).
const String errorPrintInternal = 'internal_error';

/// Voreingestelltes Zeitlimit eines Druckversuchs.
const Duration defaultPrintTimeout = Duration(seconds: 10);

/// Meldung, wenn der Drucker den Auftrag nicht mehr bestätigt hat.
///
/// Steht bewusst an einer Stelle: Treiber und Warteschlange sagen dasselbe,
/// und die Kasse zeigt den Text unverändert an.
const String unconfirmedPrintMessage =
    'Der Drucker hat nicht bestätigt — bitte prüfen, ob der Bon gedruckt '
    'wurde, sonst erneut drucken.';

/// Bekannter Zustand eines Druckers.
enum PrinterState {
  online('online'),
  offline('offline'),
  unknown('unknown');

  const PrinterState(this.wireName);

  /// Bezeichner in der API.
  final String wireName;
}

/// Anbindung an ein Druckgerät: Bytes hinschicken, Zustand abfragen.
///
/// Der Agent ist reiner Transport — die ESC/POS-Bytes entstehen in der Kasse.
abstract class PrinterDriver {
  /// Druckt [bytes]; wirft bei Misserfolg eine [PrinterFailure].
  Future<void> print(Uint8List bytes, {Duration timeout = defaultPrintTimeout});

  /// Fragt ab, ob das Gerät erreichbar ist. Wirft nicht.
  Future<PrinterState> status({Duration timeout = defaultPrintTimeout});

  /// Wirft die Verbindung des letzten Versuchs weg.
  ///
  /// Die Warteschlange ruft das **vor jeder Wiederholung** auf. Wiederholt
  /// wird nur, wenn sicher nichts hinausgegangen ist — hier hängen also keine
  /// Druckdaten mehr in der Leitung. Es geht allein um das Aufräumen: eine
  /// halb offene Verbindung des gescheiterten Versuchs soll dem zweiten nicht
  /// im Weg stehen, und der Drucker nimmt ohnehin meist nur eine gleichzeitig
  /// an. Der Aufruf muss auch dann in Ordnung gehen, wenn gerade nichts offen
  /// ist.
  Future<void> abort();
}

/// Ein Treiber, der nach dem Druck abwarten kann, bis das Gerät die
/// Verbindung seinerseits beendet hat.
///
/// Warum: `print` gilt wie bis 1.4.2 als erledigt, sobald die Bytes dem
/// Betriebssystem übergeben und die Verbindung geschlossen ist. Hält gerade
/// ein anderer Rechner einen Drucker, der nur eine Verbindung zugleich
/// bedient, liegt der Bon dann noch ungelesen in der Leitung – und welche
/// wartende Verbindung das Gerät danach zuerst bedient, sichert niemand zu
/// (Gerätetest 12.11.2026: A2 vor A1). Erst wenn das Gerät seine Seite
/// schließt, hat es den Bon ganz gelesen.
abstract interface class EndeAbwartbar {
  /// Ab dem nächsten [PrinterDriver.print]: nach dem Schließen höchstens so
  /// lange auf das Ende beim Gerät warten. [Duration.zero]: nicht warten,
  /// Verbindung sofort weg (wie bis 1.4.2).
  set endeFrist(Duration frist);

  /// Ende des letzten gelungenen Drucks: `true`, sobald das Gerät die
  /// Verbindung beendet hat, `false`, wenn die Frist ablief (dann ist sie
  /// trotzdem zu). Ohne Frist sofort `true`. Wirft nie.
  Future<bool> get ende;
}

/// Fehlgeschlagener Druckversuch mit Fachcode und deutschem Klartext.
class PrinterFailure implements Exception {
  const PrinterFailure(
    this.code,
    this.message, {
    this.detail,
    this.mayHavePrinted = false,
    this.abgelehnt = false,
  });

  /// Einer der Codes [errorPrinterOffline], [errorPrintTimeout],
  /// [errorPrintRefused].
  final String code;

  /// Text, den die Kasse unverändert anzeigt.
  final String message;

  /// Zusatz für die Fehlersuche (ePOS-Statuscode, Adresse) — nie Beleginhalt.
  final Object? detail;

  /// Ob schon Druckdaten hinausgegangen sein könnten.
  ///
  /// Der Treiber setzt das, sobald er Bytes abgeschickt hat: ab da weiß
  /// niemand mehr, ob der Bon aus dem Gerät gelaufen ist.
  final bool mayHavePrinted;

  /// Ob das Gerät die Verbindung abgelehnt hat: es ist da, nimmt gerade aber
  /// nicht an (etwa weil ein anderer Rechner es eben abfragt) – im
  /// Unterschied zu Zeitablauf oder fehlender Route.
  final bool abgelehnt;

  /// Ob ein zweiter Versuch Sinn ergibt.
  ///
  /// Wiederholt wird **nur, wenn sicher nichts hinausgegangen ist**. Ein
  /// doppelter Bon ist schlimmer als ein fehlender: der fehlende lässt sich in
  /// der Kasse nachdrucken, der doppelte steht als zweiter Beleg im Laden.
  /// Ein `refused` ist ohnehin die Antwort des Geräts selbst („kein Papier")
  /// und fiele beim zweiten Mal genauso aus.
  bool get retryable => !mayHavePrinted && code != errorPrintRefused;

  @override
  String toString() => 'PrinterFailure($code, $message)';
}

/// Ergebnis eines Druckauftrags aus Sicht der Warteschlange.
class PrintResult {
  const PrintResult.success()
    : ok = true,
      code = null,
      message = null,
      detail = null;

  const PrintResult.failure(this.code, this.message, {this.detail})
    : ok = false;

  /// Ob gedruckt wurde.
  final bool ok;

  /// Fachcode im Fehlerfall.
  final String? code;

  /// Klartext im Fehlerfall.
  final String? message;

  /// Zusatzangaben für die Kasse, z. B. `{mayHavePrinted: true, reason: …}`.
  final Map<String, Object?>? detail;

  /// Ob offen ist, dass der Bon doch gelaufen ist.
  ///
  /// Die Warteschlange entscheidet daran, ob sie sich den Auftrag merkt: nur
  /// ein Ergebnis, das ein zweiter Druck verschlimmern würde, sperrt die
  /// `jobId`.
  bool get mayHavePrinted => detail?['mayHavePrinted'] == true;

  @override
  String toString() => ok ? 'PrintResult(ok)' : 'PrintResult($code, $message)';
}
