import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Ein Aufruf am Fake-HPS.
class HpsAufruf {
  HpsAufruf(this.methode, this.pfad, this.beginn);

  final String methode;
  final String pfad;
  final DateTime beginn;
  DateTime? ende;
  String rumpf = '';
}

/// Fake eines Hobex-HPS: antwortet je Pfad nach [antwort], auf Wunsch
/// verzögert, und schreibt jeden Aufruf mit Beginn und Ende mit.
class FakeHpsServer {
  FakeHpsServer._(this._server);

  static Future<FakeHpsServer> starten({String tid = '12345678'}) async {
    final fake = FakeHpsServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    )..tid = tid;
    fake._abo = fake._server.listen(fake._bedienen);
    return fake;
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _abo;

  /// TID dieses Terminals: Diagnosen mit anderer TID melden „Invalid TID“.
  late String tid;

  /// Verzögerung je Pfad-Anfang (`/api/transaction/payment` …).
  final Map<String, Duration> verzoegerung = <String, Duration>{};

  /// Alle Aufrufe in ihrer Reihenfolge.
  final List<HpsAufruf> aufrufe = <HpsAufruf>[];

  int _offen = 0;
  int _hoechstOffen = 0;

  /// Wie viele Aufrufe höchstens gleichzeitig offen waren.
  int get hoechstGleichzeitig => _hoechstOffen;

  int get port => _server.port;

  /// Aufrufe, deren Pfad mit [anfang] beginnt.
  List<HpsAufruf> an(String anfang) =>
      aufrufe.where((a) => a.pfad.startsWith(anfang)).toList();

  Future<void> _bedienen(HttpRequest anfrage) async {
    final aufruf = HpsAufruf(anfrage.method, anfrage.uri.path, DateTime.now());
    aufrufe.add(aufruf);
    _offen++;
    if (_offen > _hoechstOffen) _hoechstOffen = _offen;
    var beendet = false;
    void beenden() {
      if (beendet) return;
      beendet = true;
      _offen--;
      aufruf.ende = DateTime.now();
    }

    try {
      aufruf.rumpf = await utf8.decoder.bind(anfrage).join();
      for (final eintrag in verzoegerung.entries) {
        if (aufruf.pfad.startsWith(eintrag.key)) {
          await Future<void>.delayed(eintrag.value);
        }
      }
      // Beendet, bevor die Antwort hinausgeht: der Absender schickt seinen
      // nächsten Aufruf erst danach, und dessen Beginn soll nie vor diesem
      // Ende liegen.
      final antwort = jsonEncode(_antwort(aufruf.pfad));
      beenden();
      anfrage.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(antwort);
      await anfrage.response.close();
    } finally {
      beenden();
    }
  }

  Map<String, Object?> _antwort(String pfad) {
    final diagnose = RegExp(
      r'^/api/terminals/(\d+)/diagnosis$',
    ).firstMatch(pfad);
    if (diagnose != null) {
      return diagnose.group(1) == tid
          ? <String, Object?>{
              'responseCode': '0',
              'tid': tid,
              'sn': 'P000000K00001',
              'mac': 'Unavailable',
            }
          : <String, Object?>{
              'responseCode': '100108',
              'responseText': 'Invalid TID',
              'tid': diagnose.group(1),
            };
    }
    return <String, Object?>{'responseCode': '0', 'tid': tid};
  }

  Future<void> stop() async {
    await _abo.cancel();
    await _server.close(force: true);
  }
}
