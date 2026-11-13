/// Aufbewahrung der Logdateien – reine Regeln ohne Dateisystem.
///
/// `connect.log` wandert bei Tageswechsel nach `connect-JJJJ-MM-TT.log` und
/// zusätzlich, sobald es [logDateiGrenze] erreicht, nach
/// `connect-JJJJ-MM-TT-n.log`. Behalten werden die Archive der letzten Tage und
/// insgesamt höchstens [logGesamtGrenze]; die älteste Datei geht zuerst.
library;

/// Größte Logdatei. Bei einem Fehler in Schleife (Drucker meldet sich jede
/// Sekunde ab) wuchs eine Tagesdatei bisher unbegrenzt; 5 MB fassen rund
/// 40 000 Zeilen – viel mehr liest beim Support niemand.
const int logDateiGrenze = 5 * 1024 * 1024;

/// Alle Logdateien zusammen. 50 MB sind auf jedem Kassenrechner verschmerzbar
/// und reichen für zehn volle Dateien.
const int logGesamtGrenze = 50 * 1024 * 1024;

final RegExp _archivName = RegExp(
  r'^connect-(\d{4}-\d{2}-\d{2})(?:-(\d{1,4}))?\.log$',
);

/// Ein Archiv neben `connect.log`.
class LogArchiv {
  const LogArchiv({
    required this.name,
    required this.tag,
    required this.teil,
    required this.bytes,
  });

  /// Dateiname (`connect-2026-11-10-2.log`).
  final String name;

  /// Tag im Namen (`2026-11-10`).
  final String tag;

  /// Nummer eines Größen-Teils; `null` für die Tagesdatei, die den Tag
  /// abschließt.
  final int? teil;

  final int bytes;

  /// Liest einen Archivnamen; `null` für jede andere Datei.
  static LogArchiv? ausName(String name, int bytes) {
    final treffer = _archivName.firstMatch(name);
    if (treffer == null) return null;
    final teil = treffer.group(2);
    return LogArchiv(
      name: name,
      tag: treffer.group(1)!,
      teil: teil == null ? null : int.parse(teil),
      bytes: bytes,
    );
  }

  /// Zeitliche Reihenfolge: nach Tag, innerhalb eines Tages die Teile nach
  /// Nummer und die Tagesdatei zuletzt (sie entsteht erst beim Tageswechsel).
  /// Nach dem Namen allein sortiert stünde `-10` vor `-2`.
  static int chronologisch(LogArchiv a, LogArchiv b) {
    final tag = a.tag.compareTo(b.tag);
    if (tag != 0) return tag;
    final ta = a.teil;
    final tb = b.teil;
    if (ta == tb) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return ta.compareTo(tb);
  }
}

/// Welche Archive weg müssen: alles außer dem [aktuellerTag] und den letzten
/// [maxTage] Tagen davor, danach so lange das älteste, bis alle Dateien samt
/// der laufenden ([aktuelleBytes]) in [maxGesamtBytes] passen.
List<String> zuLoeschendeArchive(
  Iterable<LogArchiv> archive, {
  required int maxTage,
  required String aktuellerTag,
  required int aktuelleBytes,
  int maxGesamtBytes = logGesamtGrenze,
}) {
  final sortiert = archive.toList()..sort(LogArchiv.chronologisch);
  final fruehere =
      sortiert
          .map((a) => a.tag)
          .where((t) => t != aktuellerTag)
          .toSet()
          .toList()
        ..sort();
  final behalteneTage = <String>{
    aktuellerTag,
    if (maxTage > 0)
      ...fruehere.sublist(
        fruehere.length > maxTage ? fruehere.length - maxTage : 0,
      ),
  };

  final weg = <String>[];
  final bleiben = <LogArchiv>[];
  for (final archiv in sortiert) {
    if (behalteneTage.contains(archiv.tag)) {
      bleiben.add(archiv);
    } else {
      weg.add(archiv.name);
    }
  }
  var gesamt = aktuelleBytes + bleiben.fold<int>(0, (s, a) => s + a.bytes);
  for (final archiv in bleiben) {
    if (gesamt <= maxGesamtBytes) break;
    weg.add(archiv.name);
    gesamt -= archiv.bytes;
  }
  return weg;
}

/// Name des nächsten Größen-Teils von [tag], der in [vorhanden] noch frei ist.
String naechsterTeilName(String tag, Iterable<String> vorhanden) {
  final belegt = vorhanden.toSet();
  for (var teil = 1; ; teil++) {
    final name = 'connect-$tag-$teil.log';
    if (!belegt.contains(name)) return name;
  }
}
