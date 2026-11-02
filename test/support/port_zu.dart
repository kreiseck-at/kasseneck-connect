import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// `ECONNREFUSED` je System: Linux, macOS, Windows (`WSAECONNREFUSED`).
const Set<int> _abgelehnt = <int>{111, 61, 10061};

/// Prüft, dass auf einem eben angehaltenen Port niemand mehr antwortet:
/// [anfrage] muss mit „Verbindung abgelehnt“ scheitern.
///
/// Unter Linux startet Dart Kindprozesse per `fork()`. Bis das Kind seine
/// geerbten Dateideskriptoren schließt, hält es eine Kopie jedes Sockets
/// dieses Prozesses – auch des Lauschsockets eines Servers, den ein anderer,
/// gleichzeitig laufender Test gerade angehalten hat. Eine Verbindung in
/// diesem Moment wird angenommen und beim Schließen der Kopie zurückgesetzt.
/// Ein solcher Abbruch wird deshalb bis [frist] wiederholt; eine Antwort ist
/// dagegen sofort ein Fehler.
Future<void> erwartePortZu(
  Future<Object?> Function() anfrage, {
  Duration frist = const Duration(seconds: 5),
}) async {
  final ende = DateTime.now().add(frist);
  Object? letzter;
  while (true) {
    try {
      await anfrage();
      fail('Der Port antwortet noch.');
    } on SocketException catch (e) {
      if (_abgelehnt.contains(e.osError?.errorCode)) return;
      letzter = e;
    } on TestFailure {
      rethrow;
    } on Object catch (e) {
      letzter = e;
    }
    if (DateTime.now().isAfter(ende)) {
      fail('Der Port wurde nach $frist nicht frei: $letzter');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
