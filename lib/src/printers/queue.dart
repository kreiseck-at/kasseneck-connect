import 'dart:async';
import 'dart:typed_data';

import '../events/bus.dart';
import '../log/logger.dart';
import 'driver.dart';
import 'registry.dart';

/// So lange gilt ein `jobId` als bereits erledigt.
const Duration defaultIdempotencyWindow = Duration(seconds: 60);

/// Nimmt Druckaufträge an und arbeitet sie **je Drucker seriell** ab.
///
/// Zwei Regeln bestimmen das Verhalten:
///
/// * **Idempotenz je `jobId`** — die Kasse darf denselben Auftrag nach einem
///   Netzabriss gefahrlos noch einmal schicken. Innerhalb von
///   [idempotencyWindow] kommt das erste Ergebnis zurück, ohne dass ein zweiter
///   Bon aus dem Drucker läuft.
/// * **Ein Wiederholversuch, aber nur bei Transportfehlern** — ein `refused`
///   ist die Antwort des Geräts („kein Papier"), die beim zweiten Mal genauso
///   ausfiele.
///
/// Aufträge werden bewusst **nicht** gepuffert: der Beleg ist in der Kasse
/// gespeichert, ein Nachdruck ist jederzeit möglich, und ein Drucker, der
/// Stunden später plötzlich alte Bons ausspuckt, verwirrt mehr, als er hilft.
class PrintQueue {
  PrintQueue({
    required this.registry,
    required EventBus events,
    AgentLog? log,
    DateTime Function()? clock,
    this.jobTimeout = defaultPrintTimeout,
    this.idempotencyWindow = defaultIdempotencyWindow,
  }) : _events = events,
       _log = log,
       _clock = clock ?? DateTime.now;

  final PrinterRegistry registry;
  final EventBus _events;
  final AgentLog? _log;
  final DateTime Function() _clock;

  /// Zeitlimit **je Versuch**; mit Wiederholung dauert ein Auftrag im
  /// schlimmsten Fall doppelt so lange.
  final Duration jobTimeout;

  /// Fenster, in dem ein `jobId` als erledigt gilt.
  final Duration idempotencyWindow;

  /// Laufende Kette je Drucker — daran hängt sich der nächste Auftrag an.
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// Bekannte Aufträge (laufend oder kürzlich erledigt).
  final Map<String, _JobRecord> _jobs = <String, _JobRecord>{};

  /// Nimmt einen Auftrag an und liefert das Ergebnis des Druckversuchs.
  ///
  /// Bewusst **ohne `await` vor dem Vermerk**: der Auftrag steht in [_jobs],
  /// bevor die erste Zeile asynchron wird. Sonst rutschten zwei Aufrufe mit
  /// demselben `jobId` aneinander vorbei, und der Bon käme zweimal.
  Future<PrintResult> enqueue(String printerId, String jobId, Uint8List bytes) {
    _forgetOldJobs();

    final known = _jobs[jobId];
    if (known != null) {
      final result = known.result;
      if (result != null) {
        _log?.info(
          'Auftrag $jobId ist bekannt — es wird nicht erneut gedruckt.',
        );
        return Future<PrintResult>.value(result);
      }
      return Future<PrintResult>.value(
        const PrintResult.failure(
          errorPrintInProgress,
          'Dieser Druckauftrag läuft bereits.',
        ),
      );
    }

    final record = _JobRecord(_clock());
    _jobs[jobId] = record;

    final completer = Completer<PrintResult>();
    final previous = _chains[printerId] ?? Future<void>.value();
    _chains[printerId] = previous.then((_) async {
      final driver = await registry.driverForId(printerId);
      if (driver == null) {
        // Kein Ergebnis merken: sobald der Drucker angelegt ist, soll
        // derselbe Auftrag durchgehen.
        _jobs.remove(jobId);
        completer.complete(
          const PrintResult.failure(
            errorPrinterUnknown,
            'Diesen Drucker kennt der Agent nicht.',
          ),
        );
        return;
      }
      final result = await _run(printerId, jobId, driver, bytes);
      record.finish(result, _clock());
      completer.complete(result);
    });
    return completer.future;
  }

  /// Ein Auftrag: höchstens zwei Versuche, dann steht das Ergebnis.
  Future<PrintResult> _run(
    String printerId,
    String jobId,
    PrinterDriver driver,
    Uint8List bytes,
  ) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        // Das Zeitlimit steht hier zusätzlich zum Treiber: die Warteschlange
        // verlässt sich nicht darauf, dass ein Treiber seine Zusage einhält.
        await driver.print(bytes, timeout: jobTimeout).timeout(jobTimeout);

        registry.noteState(printerId, PrinterState.online);
        _events.publish(eventPrintDone, <String, Object?>{
          'printerId': printerId,
          'jobId': jobId,
          'attempts': attempt,
        });
        return const PrintResult.success();
      } on Object catch (e) {
        final failure = _asFailure(e, printerId);
        if (failure.retryable && attempt == 1) {
          _log?.warn(
            'Auftrag $jobId an $printerId: ${failure.code} — zweiter Versuch.',
          );
          continue;
        }
        return _fail(printerId, jobId, failure, attempt);
      }
    }
    // Unerreichbar: die Schleife kehrt in jedem Zweig zurück.
    throw StateError('Druckversuche ohne Ergebnis.');
  }

  PrintResult _fail(
    String printerId,
    String jobId,
    PrinterFailure failure,
    int attempts,
  ) {
    // Ein ablehnendes Gerät hat geantwortet und ist damit erreichbar.
    registry.noteState(
      printerId,
      failure.code == errorPrintRefused
          ? PrinterState.online
          : PrinterState.offline,
    );
    _log?.error('Auftrag $jobId an $printerId: ${failure.code}');
    _events.publish(eventPrintFailed, <String, Object?>{
      'printerId': printerId,
      'jobId': jobId,
      'code': failure.code,
      'message': failure.message,
      'attempts': attempts,
    });
    return PrintResult.failure(failure.code, failure.message);
  }

  PrinterFailure _asFailure(Object error, String printerId) {
    if (error is PrinterFailure) return error;
    if (error is TimeoutException) {
      return const PrinterFailure(
        errorPrintTimeout,
        'Der Drucker hat nicht rechtzeitig geantwortet.',
      );
    }
    _log?.error('Unerwarteter Druckfehler an $printerId', error);
    return PrinterFailure(
      errorPrinterOffline,
      'Der Druck ist fehlgeschlagen.',
      detail: '$error',
    );
  }

  /// Räumt Aufträge weg, deren Fenster abgelaufen ist.
  void _forgetOldJobs() {
    final now = _clock();
    _jobs.removeWhere(
      (_, record) => now.difference(record.stamp) > idempotencyWindow,
    );
  }
}

/// Ein angenommener Auftrag: seit wann bekannt und mit welchem Ergebnis.
class _JobRecord {
  _JobRecord(this.stamp);

  /// Zeitpunkt, ab dem das Idempotenzfenster zählt (Annahme bzw. Abschluss).
  DateTime stamp;

  /// Ergebnis, sobald der Auftrag durch ist.
  PrintResult? result;

  void finish(PrintResult value, DateTime at) {
    result = value;
    stamp = at;
  }
}
