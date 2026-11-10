import 'dart:async';
import 'dart:typed_data';

import '../betrieb/vorgaenge.dart';
import '../config/model.dart';
import '../events/bus.dart';
import '../log/logger.dart';
import 'driver.dart';
import 'registry.dart';
import 'vorpruefung.dart';
import 'wiederfinden.dart';

/// So lange gilt ein `jobId` als bereits erledigt.
const Duration defaultIdempotencyWindow = Duration(seconds: 60);

/// Zuschlag auf das Zeitlimit, bevor die Warteschlange selbst abbricht.
///
/// Der Treiber soll seine eigene Zeitgrenze zuerst reißen — nur er weiß, ob
/// schon Bytes hinausgegangen sind. Der Griff der Warteschlange ist das
/// Sicherheitsnetz für einen Treiber, der gar nicht mehr antwortet.
const Duration defaultAttemptGrace = Duration(seconds: 2);

/// So lange wartet der zweite Versuch, wenn die Druckverbindung abgelehnt
/// wurde, obwohl der Drucker eben erreichbar war (Abfrage-Verbindung oder
/// eigener Bon): viele Bondrucker nehmen nur eine Verbindung zugleich an und
/// geben die vorige erst kurz nach dem Schließen frei. Gesucht wird dann
/// nicht.
const Duration nachAbfrageWarten = Duration(milliseconds: 500);

/// Nimmt Druckaufträge an und arbeitet sie **je Drucker seriell** ab.
///
/// Zwei Regeln bestimmen das Verhalten:
///
/// * **Idempotenz je Drucker und `jobId`** — die Kasse darf denselben Auftrag
///   nach einem Netzabriss gefahrlos noch einmal schicken. Innerhalb von
///   [idempotencyWindow] kommt das erste Ergebnis zurück, ohne dass ein
///   zweiter Bon aus dem Drucker läuft. Der Schlüssel enthält den Drucker:
///   derselbe Beleg an Kasse *und* Küche sind zwei Aufträge, und beide sollen
///   drucken. Gemerkt wird dabei nur, was ein zweiter Druck verschlimmern
///   könnte: Erfolge und Fehler mit offenem Ausgang. Ein sauber gescheiterter
///   Auftrag — kein Papier, Drucker aus — bleibt wiederholbar, sonst wäre der
///   Bon nach dem Beheben der Ursache eine Minute lang unerreichbar.
/// * **Ein Wiederholversuch, aber nur wenn sicher nichts hinausging** —
///   `PrinterFailure.mayHavePrinted` entscheidet. Ein `refused` ist die
///   Antwort des Geräts („kein Papier"), die beim zweiten Mal genauso ausfiele.
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
    this.attemptGrace = defaultAttemptGrace,
    this.nachErfolg,
    this.vorpruefung,
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

  /// Zuschlag, bevor die Warteschlange einen Versuch selbst abbricht.
  final Duration attemptGrace;

  /// Wird nach jedem gelungenen Druck mit der Drucker-ID gerufen (etwa um die
  /// Kennung eines Druckers nachzutragen, der noch keine hat). Darf nicht
  /// warten lassen und nicht werfen; was er anstößt, läuft für sich.
  void Function(String printerId)? nachErfolg;

  /// Prüfung vor dem ersten Versuch (Kennung, Papier, Deckel). Ohne sie
  /// läuft jeder Auftrag genau wie bis 1.4.2.
  DruckVorpruefung? vorpruefung;

  /// Sucht einen Drucker, der vor dem ersten Byte nicht erreichbar war, unter
  /// einer neuen Adresse (nur zusammen mit [vorpruefung]).
  DruckerWiederfinder? wiederfinder;

  /// Zählt jeden angenommenen Auftrag als laufenden Vorgang (Update- und
  /// Schlafsperre), vom Annehmen bis zum Ergebnis.
  LaufendeVorgaenge? vorgaenge;

  /// Laufende Kette je Drucker — daran hängt sich der nächste Auftrag an.
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// Bekannte Aufträge je `printerId|jobId` (laufend oder kürzlich erledigt).
  final Map<String, _JobRecord> _jobs = <String, _JobRecord>{};

  /// Führt [aufgabe] in der Kette von [printerId] aus: nach allen Aufträgen,
  /// die schon warten, und nie neben einem.
  ///
  /// Für alles, was außer dem Druck mit dem Gerät spricht (Kennung, Status,
  /// Wiederfinden): Viele Bondrucker nehmen nur eine Verbindung zugleich an,
  /// und eine Abfrage neben einem laufenden Bon verzögerte ihn oder risse ihn
  /// ab. Ein Fehler der Aufgabe erreicht den Aufrufer, nie die Kette.
  Future<T> exclusive<T>(String printerId, Future<T> Function() aufgabe) {
    final completer = Completer<T>();
    final previous = _chains[printerId] ?? Future<void>.value();
    final chain = previous.then((_) async {
      try {
        completer.complete(await aufgabe());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _chains[printerId] = chain.catchError((Object _) {});
    return completer.future;
  }

  /// Schlüssel eines Auftrags: ohne den Drucker verschluckte die Idempotenz
  /// den zweiten Bon derselben Bestellung auf einem anderen Gerät.
  static String jobKey(String printerId, String jobId) => '$printerId|$jobId';

  /// Nimmt einen Auftrag an und liefert das Ergebnis des Druckversuchs.
  ///
  /// Bewusst **ohne `await` vor dem Vermerk**: der Auftrag steht in [_jobs],
  /// bevor die erste Zeile asynchron wird. Sonst rutschten zwei Aufrufe mit
  /// demselben `jobId` aneinander vorbei, und der Bon käme zweimal.
  Future<PrintResult> enqueue(String printerId, String jobId, Uint8List bytes) {
    _forgetOldJobs();

    final key = jobKey(printerId, jobId);
    final known = _jobs[key];
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
    _jobs[key] = record;
    final vorgang = vorgaenge?.beginne(VorgangsArt.druck);

    final completer = Completer<PrintResult>();
    final previous = _chains[printerId] ?? Future<void>.value();

    // Der Rumpf fängt **alles** ab und erfüllt den Completer in jedem Fall:
    // sonst hinge die Anfrage der Kasse für immer, die Kette dieses Druckers
    // stünde still, und ein unbehandelter Fehler risse den Agenten mit.
    final chain = previous.then((_) async {
      var result = const PrintResult.failure(
        errorPrintInternal,
        'Der Agent konnte den Druckauftrag nicht ausführen.',
      );
      try {
        final PrinterDriver driver;
        PrinterConfig? zielDrucker;
        var abfrage = AbfrageVerlauf.keine;
        switch (await _vorbereiten(printerId, jobId)) {
          case _Unbekannt():
            // Kein Ergebnis merken: sobald der Drucker angelegt ist, soll
            // derselbe Auftrag durchgehen.
            _jobs.remove(key);
            result = const PrintResult.failure(
              errorPrinterUnknown,
              'Diesen Drucker kennt der Agent nicht.',
            );
            return;
          case _Abgelehnt(:final fehler):
            // Nachweislich nichts gesendet: nicht merken, damit derselbe
            // Auftrag nach dem Beheben (Rolle eingelegt) gleich durchgeht.
            _jobs.remove(key);
            result = _fail(printerId, jobId, fehler, 0);
            return;
          case _Bereit(:final treiber, :final ziel, :final verlauf):
            driver = treiber;
            zielDrucker = ziel;
            abfrage = verlauf;
        }
        result = await _run(
          printerId,
          jobId,
          driver,
          bytes,
          ziel: zielDrucker,
          abfrage: abfrage,
        );
        if (_worthRemembering(result)) {
          record.finish(result, _clock());
        } else {
          // Sauber gescheitert — es ist nachweislich nichts gedruckt worden.
          // Derselbe Auftrag darf es sofort noch einmal versuchen: die Kasse
          // schickt ihn nach dem Papiernachlegen mit derselben `jobId`, und
          // ein Gedächtnis, das dann „schon erledigt" antwortet, ließe den
          // Bon für immer verschwinden.
          _jobs.remove(key);
        }
      } on Object catch (e) {
        _jobs.remove(key);
        _log?.error(
          'Auftrag $jobId an $printerId ist unerwartet gescheitert',
          e,
        );
        result = PrintResult.failure(
          errorPrintInternal,
          'Der Agent konnte den Druckauftrag nicht ausführen.',
          detail: <String, Object?>{'reason': '$e'},
        );
      } finally {
        if (vorgang != null) vorgaenge?.beende(vorgang);
        if (!completer.isCompleted) completer.complete(result);
      }
    });
    // Die Kette darf nie einen Fehler tragen — der nächste Auftrag hängt daran.
    _chains[printerId] = chain.catchError((Object _) {});
    return completer.future;
  }

  /// Treiber für den Auftrag – nach der Vorprüfung, falls es eine gibt.
  Future<_Vorbereitung> _vorbereiten(String printerId, String jobId) async {
    final pruefung = vorpruefung;
    if (pruefung == null) {
      final driver = await registry.driverForId(printerId);
      return driver == null
          ? const _Unbekannt()
          : _Bereit(driver, null, AbfrageVerlauf.keine);
    }
    final config = await registry.store.load();
    PrinterConfig? drucker;
    for (final eintrag in config.printers) {
      if (eintrag.id == printerId) drucker = eintrag;
    }
    if (drucker == null) return const _Unbekannt();
    switch (await pruefung.pruefe(drucker, config)) {
      case DruckAbgelehnt(:final fehler):
        return _Abgelehnt(fehler);
      case DruckFreigabe(:final ziel, :final umgeleitet, :final abfrage):
        if (umgeleitet) {
          _log?.info(
            'Auftrag $jobId an $printerId geht an die neue Adresse '
            '${ziel.host}:${ziel.port}.',
          );
        }
        return _Bereit(registry.driverFor(ziel), ziel, abfrage);
    }
  }

  /// Ob ein Ergebnis die `jobId` für das Idempotenzfenster sperrt.
  ///
  /// Gemerkt wird nur, was ein zweiter Druck **verschlimmern** würde: der
  /// gelungene Druck und der Fehler, bei dem offen blieb, ob der Bon doch
  /// gelaufen ist. Alles andere ist ein Fehlschlag mit gesicherter Lage —
  /// nichts ist hinausgegangen, also darf die Kasse es erneut versuchen.
  static bool _worthRemembering(PrintResult result) =>
      result.ok || result.mayHavePrinted;

  /// Vergisst Kette und Aufträge eines Druckers (beim Löschen aufzurufen).
  void forgetPrinter(String printerId) {
    _chains.remove(printerId);
    _jobs.removeWhere((key, _) => key.startsWith('$printerId|'));
  }

  /// Ein Auftrag: höchstens zwei Versuche, dann steht das Ergebnis.
  ///
  /// Kam schon die Abfrage-Verbindung der Vorprüfung nicht zustande
  /// ([AbfrageVerlauf.ohneVerbindung]), war sie der erste Versuch: es folgt
  /// gleich die Suche und ein Druckversuch – ein ausgeschalteter Drucker kostet
  /// so nicht länger als bis 1.4.2.
  Future<PrintResult> _run(
    String printerId,
    String jobId,
    PrinterDriver driver,
    Uint8List bytes, {
    PrinterConfig? ziel,
    AbfrageVerlauf abfrage = AbfrageVerlauf.keine,
  }) async {
    var attempt = 1;
    if (abfrage == AbfrageVerlauf.ohneVerbindung) {
      _log?.warn(
        'Auftrag $jobId an $printerId: schon die Abfrage fand keinen Drucker '
        '– ein Druckversuch.',
      );
      final neu = await _anderswo(jobId, printerId, ziel);
      if (neu != null) {
        driver = registry.driverFor(neu);
        ziel = neu;
      }
      attempt = 2;
    }
    for (; attempt <= 2; attempt++) {
      try {
        // Das Zeitlimit steht hier zusätzlich zum Treiber: die Warteschlange
        // verlässt sich nicht darauf, dass ein Treiber seine Zusage einhält.
        // Der Zuschlag lässt dem Treiber den Vortritt — nur er weiß, ob schon
        // Bytes hinausgegangen sind.
        await driver
            .print(bytes, timeout: jobTimeout)
            .timeout(jobTimeout + attemptGrace);

        _gesendet(printerId, bytes);
        registry.noteState(printerId, PrinterState.online);
        nachErfolg?.call(printerId);
        _events.publish(eventPrintDone, <String, Object?>{
          'printerId': printerId,
          'jobId': jobId,
          'attempts': attempt,
        });
        return const PrintResult.success();
      } on Object catch (e) {
        final failure = _asFailure(e, printerId);
        if (failure.mayHavePrinted) _gesendet(printerId, bytes);
        final nichtsGesendet =
            failure.code == errorPrinterOffline && !failure.mayHavePrinted;
        // Eben war der Drucker erreichbar: er gibt nur die vorige Verbindung
        // noch nicht frei.
        final ebenErreichbar =
            nichtsGesendet && abfrage == AbfrageVerlauf.ebenErreichbar;
        if (failure.retryable && attempt == 1) {
          _log?.warn(
            'Auftrag $jobId an $printerId: ${failure.code} — zweiter Versuch.',
          );
          // Erst die alte Verbindung wegwerfen, dann neu ansetzen.
          await driver.abort();
          if (ebenErreichbar) {
            await Future<void>.delayed(nachAbfrageWarten);
            continue;
          }
          // Keine Verbindung vor dem ersten Byte: vielleicht hat der Drucker
          // eine neue Adresse. Dort zu drucken ist sicher, denn nachweislich
          // ging noch nichts hinaus.
          if (nichtsGesendet) {
            final neu = await _anderswo(jobId, printerId, ziel);
            if (neu != null) {
              driver = registry.driverFor(neu);
              ziel = neu;
            }
          }
          continue;
        }
        if (nichtsGesendet && !ebenErreichbar) {
          wiederfinder?.gruendlichImHintergrund(printerId);
        }
        return _fail(printerId, jobId, failure, attempt);
      }
    }
    // Unerreichbar: die Schleife kehrt in jedem Zweig zurück.
    throw StateError('Druckversuche ohne Ergebnis.');
  }

  /// Sucht [ziel] schnell unter einer neuen Adresse; `null` ohne Fund (oder
  /// ohne Wiederfinden, etwa auf dem Weg ohne Vorprüfung).
  Future<PrinterConfig?> _anderswo(
    String jobId,
    String printerId,
    PrinterConfig? ziel,
  ) async {
    final suche = wiederfinder;
    if (ziel == null || suche == null) return null;
    final neu = await suche.schnell(ziel);
    if (neu != null) {
      _log?.info(
        'Auftrag $jobId an $printerId geht an die neue Adresse '
        '${neu.host}:${neu.port}.',
      );
    }
    return neu;
  }

  /// Merkt sich, dass gerade ein Bon an [printerId] hinausging: bis er
  /// vermutlich gedruckt ist, gilt Schweigen des Druckers als unbekannt.
  void _gesendet(String printerId, Uint8List bytes) =>
      registry.lagen.von(printerId).druckGesendet(bytes.length, _clock());

  PrintResult _fail(
    String printerId,
    String jobId,
    PrinterFailure failure,
    int attempts,
  ) {
    // Ein ablehnendes Gerät hat geantwortet und ist damit erreichbar –
    // ebenso eines, das Papierende oder offenen Deckel meldet.
    registry.noteState(
      printerId,
      failure.code == errorPrintRefused ||
              failure.code == errorPaperOut ||
              failure.code == errorCoverOpen ||
              failure.code == errorPrinterNotReady
          ? PrinterState.online
          : PrinterState.offline,
    );
    // Der Zusatz des Treibers (ePOS-Statuscode, Socket-Meldung) gehört ins
    // Log **und** in die Antwort: ohne ihn steht dort nur „printer_offline",
    // und der Support fragt zurück, was das Gerät denn gesagt hat. Beleginhalt
    // steht nie darin — das sichert der Treiber zu.
    final reason = failure.detail;
    _log?.error(
      'Auftrag $jobId an $printerId: ${failure.code}'
      '${reason == null ? '' : ' ($reason)'}',
    );
    _events.publish(eventPrintFailed, <String, Object?>{
      'printerId': printerId,
      'jobId': jobId,
      'code': failure.code,
      'message': failure.message,
      'attempts': attempts,
      if (failure.mayHavePrinted) 'mayHavePrinted': true,
    });
    return PrintResult.failure(
      failure.code,
      failure.message,
      detail: (failure.mayHavePrinted || reason != null)
          ? <String, Object?>{
              if (failure.mayHavePrinted) 'mayHavePrinted': true,
              if (reason != null) 'reason': '$reason',
            }
          : null,
    );
  }

  PrinterFailure _asFailure(Object error, String printerId) {
    if (error is PrinterFailure) return error;
    if (error is TimeoutException) {
      // Der Treiber hat sein eigenes Zeitlimit verschlafen: ob etwas
      // hinausging, weiß hier niemand mehr — also kein zweiter Versuch.
      return const PrinterFailure(
        errorPrintTimeout,
        unconfirmedPrintMessage,
        mayHavePrinted: true,
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

/// Was vor dem ersten Versuch feststeht.
sealed class _Vorbereitung {
  const _Vorbereitung();
}

/// Den Drucker gibt es nicht.
final class _Unbekannt extends _Vorbereitung {
  const _Unbekannt();
}

/// Die Vorprüfung lehnt ab: kein Byte hinaus.
final class _Abgelehnt extends _Vorbereitung {
  const _Abgelehnt(this.fehler);

  final PrinterFailure fehler;
}

/// Drucken mit [treiber] an [ziel] (`null` auf dem Weg ohne Vorprüfung).
final class _Bereit extends _Vorbereitung {
  const _Bereit(this.treiber, this.ziel, this.verlauf);

  final PrinterDriver treiber;
  final PrinterConfig? ziel;

  /// Was die Abfrage-Verbindung der Vorprüfung erlebte.
  final AbfrageVerlauf verlauf;
}
