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

  /// Bricht einen laufenden Versuch ab (Verbindung wegwerfen).
  ///
  /// Die Warteschlange ruft das **vor jeder Wiederholung** auf: sonst hinge
  /// womöglich noch die erste Verbindung am Drucker, und die Bytes des ersten
  /// Versuchs kämen doch noch hinterher.
  Future<void> abort();
}

/// Fehlgeschlagener Druckversuch mit Fachcode und deutschem Klartext.
class PrinterFailure implements Exception {
  const PrinterFailure(
    this.code,
    this.message, {
    this.detail,
    this.mayHavePrinted = false,
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

  /// Zusatzangaben für die Kasse, z. B. `{mayHavePrinted: true}`.
  final Map<String, Object?>? detail;

  @override
  String toString() => ok ? 'PrintResult(ok)' : 'PrintResult($code, $message)';
}
