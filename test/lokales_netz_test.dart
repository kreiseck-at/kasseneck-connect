import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

/// Ein Socket-Fehler mit dem Betriebssystem-Fehler [errno] – die Werte sind
/// fest gewählt, damit die Prüfung auf jedem Rechner gleich läuft.
SocketException fehler(int errno, [String text = 'No route to host']) =>
    SocketException('Connection failed', osError: OSError(text, errno));

void main() {
  group('Hinweis auf die Freigabe „Lokales Netzwerk“', () {
    test('nur am Mac und nur bei „No route to host“ (errno 65)', () {
      expect(
        lokalesNetzHinweis(fehler(65), betriebssystem: 'macos'),
        lokalesNetzHinweisText,
      );
      // Unter Linux heißt 65 etwas anderes, und eine Freigabe gibt es nicht.
      expect(lokalesNetzHinweis(fehler(65), betriebssystem: 'linux'), isNull);
      expect(lokalesNetzHinweis(fehler(113), betriebssystem: 'linux'), isNull);
      expect(lokalesNetzHinweis(fehler(65), betriebssystem: 'windows'), isNull);
      // Abgelehnt (61) oder abgelaufen (60) ist am Mac kein Freigabe-Fall.
      expect(
        lokalesNetzHinweis(
          fehler(61, 'Connection refused'),
          betriebssystem: 'macos',
        ),
        isNull,
      );
      expect(
        lokalesNetzHinweis(
          fehler(60, 'Operation timed out'),
          betriebssystem: 'macos',
        ),
        isNull,
      );
      expect(
        lokalesNetzHinweis(
          const SocketException('HTTP connection timed out'),
          betriebssystem: 'macos',
        ),
        isNull,
      );
      expect(
        lokalesNetzHinweis(const FormatException(), betriebssystem: 'macos'),
        isNull,
      );
    });

    test('der Satz führt den Weg in den Systemeinstellungen', () {
      expect(lokalesNetzHinweisText, contains('Datenschutz & Sicherheit'));
      expect(lokalesNetzHinweisText, contains('Lokales Netzwerk'));
      expect(lokalesNetzHinweisText, contains('„Kasseneck Connect“'));
      expect(lokalesNetzHinweisText, isNot(contains('—')));
    });

    test('mitLokalesNetzHinweis hängt den Satz an oder lässt die Meldung', () {
      expect(
        mitLokalesNetzHinweis('Weg.', fehler(65), betriebssystem: 'macos'),
        'Weg. $lokalesNetzHinweisText',
      );
      expect(
        mitLokalesNetzHinweis('Weg.', fehler(65), betriebssystem: 'linux'),
        'Weg.',
      );
    });
  });

  test('socketGrund nennt den Betriebssystem-Fehler mit', () {
    expect(
      socketGrund(fehler(65)),
      'Connection failed (No route to host, errno 65)',
    );
    expect(socketGrund(const SocketException('nur Text')), 'nur Text');
    expect(
      socketGrund(
        const SocketException('', osError: OSError('Host is down', 64)),
      ),
      'Host is down, errno 64',
    );
  });
}
