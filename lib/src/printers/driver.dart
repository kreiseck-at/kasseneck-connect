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

/// Voreingestelltes Zeitlimit eines Druckversuchs.
const Duration defaultPrintTimeout = Duration(seconds: 10);

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
}

/// Fehlgeschlagener Druckversuch mit Fachcode und deutschem Klartext.
class PrinterFailure implements Exception {
  const PrinterFailure(this.code, this.message, {this.detail});

  /// Einer der Codes [errorPrinterOffline], [errorPrintTimeout],
  /// [errorPrintRefused].
  final String code;

  /// Text, den die Kasse unverändert anzeigt.
  final String message;

  /// Zusatz für die Fehlersuche (ePOS-Statuscode, Adresse) — nie Beleginhalt.
  final Object? detail;

  /// Ob ein zweiter Versuch Sinn ergibt.
  ///
  /// Nur Transportfehler werden wiederholt. Ein `refused` ist die Antwort des
  /// Geräts selbst („kein Papier"): der zweite Versuch scheiterte genauso und
  /// verzögerte nur die Meldung an die Kasse.
  bool get retryable => code != errorPrintRefused;

  @override
  String toString() => 'PrinterFailure($code, $message)';
}

/// Ergebnis eines Druckauftrags aus Sicht der Warteschlange.
class PrintResult {
  const PrintResult.success() : ok = true, code = null, message = null;

  const PrintResult.failure(this.code, this.message) : ok = false;

  /// Ob gedruckt wurde.
  final bool ok;

  /// Fachcode im Fehlerfall.
  final String? code;

  /// Klartext im Fehlerfall.
  final String? message;

  @override
  String toString() => ok ? 'PrintResult(ok)' : 'PrintResult($code, $message)';
}
