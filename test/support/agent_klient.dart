import 'dart:convert';
import 'dart:io';

/// Herkunft der Kasse für Anfragen im Test.
const String kasseHerkunft = 'https://kasse.kasseneck.at';

/// Antwort des Agenten in bequemer Form.
class AgentAntwort {
  AgentAntwort(this.status, this.text);

  final int status;
  final String text;

  Map<String, Object?> get json => jsonDecode(text) as Map<String, Object?>;

  bool get ok => json['ok'] == true;

  String? get code {
    final error = json['error'];
    return error is Map ? error['code'] as String? : null;
  }

  Map<String, Object?>? get detail {
    final error = json['error'];
    return error is Map ? error['detail'] as Map<String, Object?>? : null;
  }
}

/// Schickt eine Anfrage an den Agenten auf [port] – wie die Kasse: mit
/// Herkunft und, falls angegeben, Token.
Future<AgentAntwort> anAgent(
  int port,
  String methode,
  String pfad, {
  String? token,
  Object? rumpf,
  String herkunft = kasseHerkunft,
}) async {
  final client = HttpClient();
  try {
    final anfrage = await client.openUrl(
      methode,
      Uri.parse('http://127.0.0.1:$port$pfad'),
    );
    anfrage.headers.set('origin', herkunft);
    if (token != null) anfrage.headers.set('authorization', 'Bearer $token');
    if (rumpf != null) {
      anfrage.headers.contentType = ContentType.json;
      anfrage.write(jsonEncode(rumpf));
    }
    final antwort = await anfrage.close();
    return AgentAntwort(
      antwort.statusCode,
      await antwort.transform(utf8.decoder).join(),
    );
  } finally {
    client.close(force: true);
  }
}

/// Wartet, bis [bedingung] wahr ist (höchstens [frist]).
Future<void> warteBis(
  Future<bool> Function() bedingung, {
  Duration frist = const Duration(seconds: 5),
  String grund = 'Bedingung',
}) async {
  final ende = DateTime.now().add(frist);
  while (!await bedingung()) {
    if (DateTime.now().isAfter(ende)) {
      throw StateError('$grund nicht erfüllt nach $frist');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
