@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Der Deinstallierer für macOS. Ausgeführt wird er im Test nie (er braucht
/// root und fasst den Schlüsselbund an); geprüft werden seine Auswahl-
/// Funktionen mit echtem `awk` und die Aufrufe im Text.
final File _skript = File(
  p.join(Directory.current.path, 'tool', 'pkg', 'macos', 'uninstall.sh'),
);

const String _name = 'Kasseneck Connect (lokal)';

void main() {
  late String text;
  late List<String> zeilen;
  late Directory temp;

  setUp(() {
    text = _skript.readAsStringSync();
    zeilen = text.split('\n');
    temp = Directory.systemTemp.createTempSync('connect-uninstall-');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// Führt [befehl] in einer bash aus, die nur den Auswahl-Abschnitt des
  /// Skripts kennt.
  Future<ProcessResult> mitAuswahl(String befehl, {String? eingabe}) async {
    final start = text.indexOf('# >>> Auswahl im Schlüsselbund');
    final ende = text.indexOf('# <<< Auswahl im Schlüsselbund');
    expect(start, greaterThan(0));
    expect(ende, greaterThan(start));
    final auswahl = File(p.join(temp.path, 'auswahl.sh'))
      ..writeAsStringSync(text.substring(start, ende));
    final prozess = await Process.start('bash', <String>[
      '-c',
      'source "\$1"; $befehl',
      'bash',
      auswahl.path,
    ]);
    if (eingabe != null) prozess.stdin.write(eingabe);
    await prozess.stdin.close();
    final ausgabe = prozess.stdout.transform(utf8.decoder).join();
    final fehler = prozess.stderr.transform(utf8.decoder).join();
    return ProcessResult(
      prozess.pid,
      await prozess.exitCode,
      await ausgabe,
      await fehler,
    );
  }

  test('Syntax ist gültig (bash -n)', () async {
    final r = await Process.run('bash', <String>['-n', _skript.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });

  test(
    'Vertrauen verliert nur, wessen Bezeichnung genau der Name ist',
    () async {
      final r = await mitAuswahl(
        'exact_label_hashes "$_name"',
        eingabe: <String>[
          _treffer('A' * 40, _name),
          _treffer('B' * 40, 'Meine $_name Kopie'),
          _treffer('C' * 40, '$_name 2'),
          _treffer('D' * 40, 'Fremd'),
        ].join(),
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}'.trim().split('\n'), <String>['A' * 40]);
    },
  );

  test('nur die gewünschten PEMs werden abgelegt, Byte für Byte', () async {
    final pemA = _pem('Stelle A');
    final pemB = _pem('Stelle B');
    final pemC = _pem('fremd');
    final ziel = Directory(p.join(temp.path, 'pems'))..createSync();
    final r = await mitAuswahl(
      'write_pems "${ziel.path}" "${'A' * 40} ${'C' * 40}"',
      eingabe: <String>[
        _trefferPem('A' * 40, pemA),
        _trefferPem('B' * 40, pemB),
        _trefferPem('C' * 40, pemC),
      ].join(),
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(ziel.listSync().map((f) => p.basename(f.path)).toSet(), <String>{
      '${'A' * 40}.pem',
      '${'C' * 40}.pem',
    });
    expect(File(p.join(ziel.path, '${'A' * 40}.pem')).readAsStringSync(), pemA);
    expect(File(p.join(ziel.path, '${'C' * 40}.pem')).readAsStringSync(), pemC);
  });

  final ohneOpenssl = File('/usr/bin/openssl').existsSync()
      ? null
      : 'kein /usr/bin/openssl';

  test(
    'sha1_of rechnet wie security (Großbuchstaben, ohne Doppelpunkte)',
    () async {
      final dateien = await LocalCertificates(
        directory: temp,
        run: Process.run,
        log: AgentLog(Directory(p.join(temp.path, 'logs'))),
      ).ensure();
      final pem = File(dateien.caCertPath).readAsStringSync();
      final der = base64.decode(
        pem
            .replaceAll('-----BEGIN CERTIFICATE-----', '')
            .replaceAll('-----END CERTIFICATE-----', '')
            .replaceAll(RegExp(r'\s'), ''),
      );

      final r = await mitAuswahl('sha1_of "${dateien.caCertPath}"');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect('${r.stdout}'.trim(), sha1.convert(der).toString().toUpperCase());

      final kaputt = File(p.join(temp.path, 'kaputt.pem'))
        ..writeAsStringSync('kein Zertifikat');
      expect(
        '${(await mitAuswahl('sha1_of "${kaputt.path}"')).stdout}'.trim(),
        '',
      );
    },
    skip: ohneOpenssl,
  );

  group('Aufrufe im Text', () {
    test('gelöscht wird nur per Fingerabdruck der eigenen ca-cert.pem', () {
      final loeschen = zeilen
          .where((z) => z.contains('delete-certificate'))
          .toList();
      expect(loeschen, hasLength(1), reason: loeschen.join('\n'));
      final aufruf = loeschen.single;
      expect(aufruf, contains('delete-certificate -Z "\$CA_SHA1"'));
      expect(aufruf, isNot(contains(' -c ')));
      expect(aufruf, isNot(contains(' -t')));

      // CA_SHA1 kommt nur aus der eigenen Datei, und gelöscht wird nur,
      // wenn er feststeht.
      final zuweisungen = zeilen
          .map((z) => z.trim())
          .where((z) => z.startsWith('CA_SHA1='))
          .toList();
      expect(zuweisungen, <String>[
        'CA_SHA1=""',
        r'CA_SHA1="$(sha1_of "$CA_CERT")"',
      ]);
      final index = zeilen.indexOf(aufruf);
      expect(zeilen[index - 1].trim(), r'if [ -n "$CA_SHA1" ]; then');
      expect(
        text,
        contains(
          r'CA_CERT="$CONSOLE_HOME/Library/Application Support/'
          'KasseneckConnect/tls/ca-cert.pem"',
        ),
      );
    });

    test('Vertrauen wird nur über die genaue Bezeichnung oder die eigene '
        'Datei entzogen', () {
      final entziehen = zeilen
          .where((z) => z.contains('remove-trusted-cert'))
          .map((z) => z.trim())
          .toList();
      expect(entziehen, <String>[
        r'as_console_user /usr/bin/security remove-trusted-cert "$PEM" \',
        r'as_console_user /usr/bin/security remove-trusted-cert "$CA_CERT" \',
      ]);
      // Die PEMs stammen aus der genauen Auswahl.
      expect(text, contains(r'| exact_label_hashes "$CA_NAME"'));
      expect(text, contains(r'| write_pems "$CERT_DIR" "$WANTED"'));
    });

    test('Pfade und Namen stehen immer in Anführungszeichen', () {
      final variable = RegExp(
        r'\$(CA_CERT|KEYCHAIN|PEM|CERT_DIR|CA_NAME|CONSOLE_HOME|WANTED|CA_SHA1)\b',
      );
      for (final (nummer, zeile) in zeilen.indexed) {
        if (zeile.trimLeft().startsWith('#')) continue;
        for (final treffer in variable.allMatches(zeile)) {
          // In `$(…)` beginnen die Anführungszeichen von vorn.
          var davor = zeile.substring(0, treffer.start);
          final klammer = davor.lastIndexOf(r'$(');
          if (klammer >= 0) davor = davor.substring(klammer);
          final anfuehrungen = '"'
              .allMatches(davor.replaceAll(r'\"', ''))
              .length;
          final inKlammer = davor.contains(r'${');
          expect(
            anfuehrungen.isOdd || inKlammer,
            isTrue,
            reason: 'Zeile ${nummer + 1}: $zeile',
          );
        }
      }
    });
  });
}

/// Ein Treffer von `security find-certificate -a -Z` mit Bezeichnung [label].
String _treffer(String sha1, String label) =>
    'SHA-256 hash: ${'0' * 64}\n'
    'SHA-1 hash: $sha1\n'
    'keychain: "/Users/beispiel/Library/Keychains/login.keychain-db"\n'
    'version: 512\n'
    'class: 0x80001000 \n'
    'attributes:\n'
    '    "alis"<blob>="$label"\n'
    '    "labl"<blob>="$label"\n';

/// Ein Treffer von `security find-certificate -a -Z -p`.
String _trefferPem(String sha1, String pem) =>
    'SHA-256 hash: ${'0' * 64}\nSHA-1 hash: $sha1\n$pem';

/// Ein erfundenes PEM: richtiges Format, beliebiger Inhalt.
String _pem(String inhalt) {
  final b64 = base64.encode(utf8.encode(inhalt.padRight(60, '.')));
  return '-----BEGIN CERTIFICATE-----\n$b64\n-----END CERTIFICATE-----\n';
}
