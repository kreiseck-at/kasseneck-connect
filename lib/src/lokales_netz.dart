import 'dart:io';

/// `EHOSTUNREACH` („No route to host“) unter macOS.
///
/// Mit genau diesem Fehler lässt macOS eine Verbindung ins lokale Netz
/// scheitern, wenn dem Programm die Freigabe „Lokales Netzwerk“ fehlt (seit
/// macOS 15). Derselbe Wert steht auch für ein echt unerreichbares Ziel –
/// deshalb ist der Hinweis unten als Möglichkeit formuliert, nie als Befund.
/// Unter Linux hat `EHOSTUNREACH` die Nummer 113; dort gibt es die Freigabe
/// nicht, und der Hinweis bleibt weg.
const int macosEhostunreach = 65;

/// Satz, den Drucker- und Terminalmeldungen am Mac anhängen, wenn die
/// Verbindung mit [macosEhostunreach] scheiterte.
const String lokalesNetzHinweisText =
    'Sind Gerät und Netz in Ordnung, fehlt am Mac vielleicht die Freigabe: '
    'Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk → '
    '„Kasseneck Connect“ einschalten.';

/// Der Hinweis auf die macOS-Freigabe „Lokales Netzwerk“, wenn [fehler] danach
/// aussieht – sonst `null`.
///
/// [betriebssystem] ersetzt im Test `Platform.operatingSystem`: der Fehlerwert
/// ist je System ein anderer, und die Prüfung soll auf jedem Rechner dieselbe
/// sein.
String? lokalesNetzHinweis(Object fehler, {String? betriebssystem}) {
  if ((betriebssystem ?? Platform.operatingSystem) != 'macos') return null;
  if (fehler is! SocketException) return null;
  return fehler.osError?.errorCode == macosEhostunreach
      ? lokalesNetzHinweisText
      : null;
}

/// [meldung] samt Hinweis auf die Freigabe, wenn [lokalesNetzHinweis] einen
/// liefert.
String mitLokalesNetzHinweis(
  String meldung,
  Object fehler, {
  String? betriebssystem,
}) {
  final hinweis = lokalesNetzHinweis(fehler, betriebssystem: betriebssystem);
  return hinweis == null ? meldung : '$meldung $hinweis';
}

/// Die Socket-Meldung samt Betriebssystem-Fehler für Log und `detail.reason`.
///
/// `SocketException.message` allein sagt oft nur „Connection failed“ – ob
/// abgelehnt, ohne Route oder abgelaufen, steht erst im `osError`.
String socketGrund(SocketException fehler) {
  final os = fehler.osError;
  if (os == null) return fehler.message;
  final betriebssystem = '${os.message}, errno ${os.errorCode}';
  return fehler.message.isEmpty
      ? betriebssystem
      : '${fehler.message} ($betriebssystem)';
}
