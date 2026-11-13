import 'discovery.dart';

/// So lange gilt ein Fund der Druckersuche samt Modell und Seriennummer aus
/// mDNS. Die Kasse legt einen Drucker meist gleich nach der Suche an; später
/// kommt die Kennung aus `GS I` und ARP.
const Duration fundGedaechtnis = Duration(minutes: 10);

/// Merkt sich die letzten Funde der Druckersuche je Adresse.
///
/// Beim Anlegen (`PUT /v1/printers`) weiß Connect so, was mDNS über das Gerät
/// unter dieser Adresse gesagt hat, ohne erneut zu suchen.
class FundGedaechtnis {
  FundGedaechtnis({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  final Map<String, ({DiscoveredPrinter fund, DateTime am})> _funde =
      <String, ({DiscoveredPrinter fund, DateTime am})>{};

  /// Merkt sich [funde] und vergisst, was älter als [fundGedaechtnis] ist.
  void merke(Iterable<DiscoveredPrinter> funde) {
    final jetzt = _clock();
    for (final fund in funde) {
      _funde[fund.key] = (fund: fund, am: jetzt);
    }
    _funde.removeWhere((_, g) => _abgelaufen(g.am, jetzt));
  }

  /// Der Fund unter [host]:[port], wenn er jung genug ist.
  DiscoveredPrinter? unter(String host, int port) {
    final gemerkt = _funde['$host:$port'];
    if (gemerkt == null || _abgelaufen(gemerkt.am, _clock())) return null;
    return gemerkt.fund;
  }

  static bool _abgelaufen(DateTime am, DateTime jetzt) {
    final alter = jetzt.difference(am);
    return alter.isNegative || alter > fundGedaechtnis;
  }
}
