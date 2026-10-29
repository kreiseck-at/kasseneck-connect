import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

const String _security = '/usr/bin/security';

void main() {
  late Directory temp;
  late String home;
  late String keychain;
  late String caPfad;
  late String serverPfad;
  late FakeProcessRunner fake;

  /// Die aktuelle Stelle auf der Platte (Inhalt erfunden — für die
  /// Fingerabdrücke zählen nur die Bytes).
  final aktuell = _pem('aktuelle Stelle');

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-trust-');
    home = p.join(temp.path, 'home');
    keychain = p.join(home, 'Library', 'Keychains', 'login.keychain-db');
    final tls = Directory(p.join(temp.path, 'daten', 'tls'))
      ..createSync(recursive: true);
    caPfad = p.join(tls.path, 'ca-cert.pem');
    serverPfad = p.join(tls.path, 'server-cert.pem');
    File(caPfad).writeAsStringSync(aktuell);
    File(serverPfad).writeAsStringSync(_pem('Serverzertifikat'));
    fake = FakeProcessRunner()
      // Ohne eigene Regel: keine Stelle gleichen Namens im Schlüsselbund
      // (so antwortet `security`, wenn nichts passt) und nicht vertraut.
      ..exitCodes['find-certificate'] = 44
      ..exitCodes['verify-cert'] = 1;
  });

  tearDown(() => temp.deleteSync(recursive: true));

  List<String> unterbefehle() => fake.calls
      .where((c) => c.executable == _security)
      .map((c) => c.arguments.first)
      .toList();

  group('isLocalCaTrusted', () {
    test('fragt macOS nach der Kette des Serverzertifikats (SSL)', () async {
      fake.exitCodes['verify-cert'] = 0;

      expect(await isLocalCaTrusted(caPfad, run: fake.runner), isTrue);

      // Eine Stelle allein lässt sich mit der SSL-Richtlinie nicht prüfen
      // (macOS verlangt am Blatt serverAuth) — geprüft wird darum die Kette
      // daneben, so wie Safari sie sieht, ohne Netz.
      expect(fake.calls.single.executable, _security);
      expect(fake.calls.single.arguments, <String>[
        'verify-cert',
        '-c',
        serverPfad,
        '-c',
        caPfad,
        '-p',
        'ssl',
        '-L',
        '-q',
      ]);
    });

    test('nicht vertraut: false', () async {
      expect(await isLocalCaTrusted(caPfad, run: fake.runner), isFalse);
    });

    test('ausdrücklicher Pfad des Serverzertifikats', () async {
      final anderes = p.join(temp.path, 'anderes.pem');
      await isLocalCaTrusted(caPfad, run: fake.runner, serverCertPath: anderes);
      expect(fake.calls.single.arguments[2], anderes);
    });

    test('ohne security (kein Mac): nicht vertraut, kein Absturz', () async {
      fake.missing.add(_security);
      expect(await isLocalCaTrusted(caPfad, run: fake.runner), isFalse);
    });

    test('hängt security, gilt es als nicht vertraut', () async {
      fake.antwort = (_, _) => Completer<ProcessResult>().future;
      expect(
        await isLocalCaTrusted(
          caPfad,
          run: fake.runner,
          timeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });
  });

  group('trustLocalCa', () {
    test('trägt die Stelle mit genau diesen Argumenten in den Anmelde-'
        'Schlüsselbund ein', () async {
      expect(await trustLocalCa(caPfad, run: fake.runner, home: home), isTrue);

      expect(
        fake.sawCall(_security, <String>[
          'add-trusted-cert',
          '-r',
          'trustRoot',
          '-p',
          'ssl',
          '-k',
          keychain,
          caPfad,
        ]),
        isTrue,
        reason: fake.lines.join('\n'),
      );
      expect(unterbefehle(), <String>[
        'find-certificate',
        'verify-cert',
        'add-trusted-cert',
      ]);
      // Gesucht wird nur im Anmelde-Schlüsselbund, nach dem Namen der Stelle.
      expect(fake.calls.first.arguments, <String>[
        'find-certificate',
        '-a',
        '-Z',
        '-p',
        '-c',
        localCaName,
        keychain,
      ]);
    });

    test(
      'schon vertraute Stelle: keine Frage, kein add-trusted-cert',
      () async {
        fake.exitCodes['verify-cert'] = 0;

        expect(
          await trustLocalCa(caPfad, run: fake.runner, home: home),
          isTrue,
        );
        expect(unterbefehle(), isNot(contains('add-trusted-cert')));
      },
    );

    test('gleiche Stelle schon im Schlüsselbund, aber nicht vertraut: '
        'eintragen', () async {
      fake.exitCodes.remove('find-certificate');
      fake.stdoutOf['find-certificate'] = _fundstelle(aktuell);

      expect(await trustLocalCa(caPfad, run: fake.runner, home: home), isTrue);
      expect(unterbefehle(), <String>[
        'find-certificate',
        'verify-cert',
        'add-trusted-cert',
      ]);
    });

    test('abgebrochene Frage (Exitcode ≠ 0): false', () async {
      fake.exitCodes['add-trusted-cert'] = 1;
      expect(await trustLocalCa(caPfad, run: fake.runner, home: home), isFalse);
    });

    test('Frage ohne Antwort bricht nach der Wartezeit ab', () async {
      fake.antwort = (programm, argumente) =>
          argumente.first == 'add-trusted-cert'
          ? Completer<ProcessResult>().future
          : Future<ProcessResult?>.value();
      expect(
        await trustLocalCa(
          caPfad,
          run: fake.runner,
          home: home,
          promptTimeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });

    test('ohne security: false, kein Absturz', () async {
      fake.missing.add(_security);
      expect(await trustLocalCa(caPfad, run: fake.runner, home: home), isFalse);
    });

    test('unlesbare Stelle: false, kein security-Aufruf', () async {
      File(caPfad).writeAsStringSync('kein Zertifikat');
      expect(await trustLocalCa(caPfad, run: fake.runner, home: home), isFalse);
      expect(fake.calls, isEmpty);
    });

    group('Stellen gleichen Namens', () {
      final alt = _pem('alte Stelle');

      /// `trust-settings-export` schreibt die Liste der vertrauten
      /// Zertifikate (Schlüssel: SHA-1) in die Datei, die es bekommt.
      void vertraut(Iterable<String> pems, {int exitCode = 0}) {
        fake.exitCodes.remove('find-certificate');
        fake.stdoutOf['find-certificate'] =
            _fundstelle(alt) + _fundstelle(aktuell);
        fake.antwort = (programm, argumente) async {
          if (argumente.first != 'trust-settings-export') return null;
          File(
            argumente.last,
          ).writeAsStringSync(_vertrauensliste(pems.map(_sha1)));
          return ProcessResult(1, exitCode, '', '');
        };
      }

      test('einer alten vertrauten Stelle wird zuerst das Vertrauen '
          'entzogen', () async {
        vertraut(<String>[alt]);
        String? entzogen;
        final vorher = fake.antwort!;
        fake.antwort = (programm, argumente) async {
          if (argumente.first == 'remove-trusted-cert') {
            entzogen = File(argumente.last).readAsStringSync();
          }
          return vorher(programm, argumente);
        };

        expect(
          await trustLocalCa(caPfad, run: fake.runner, home: home),
          isTrue,
        );

        expect(unterbefehle(), <String>[
          'find-certificate',
          'trust-settings-export',
          'remove-trusted-cert',
          'verify-cert',
          'add-trusted-cert',
        ]);
        expect(entzogen, alt);
        // Die Datei mit der alten Stelle bleibt nicht liegen.
        final remove = fake.calls.singleWhere(
          (c) => c.arguments.first == 'remove-trusted-cert',
        );
        expect(remove.arguments, hasLength(2));
        expect(File(remove.arguments.last).existsSync(), isFalse);
        final export = fake.calls.singleWhere(
          (c) => c.arguments.first == 'trust-settings-export',
        );
        expect(export.arguments, hasLength(2));
        expect(File(export.arguments.last).existsSync(), isFalse);
      });

      test('auch wenn die aktuelle Stelle schon vertraut ist', () async {
        vertraut(<String>[alt, aktuell]);
        fake.exitCodes['verify-cert'] = 0;

        expect(
          await trustLocalCa(caPfad, run: fake.runner, home: home),
          isTrue,
        );
        expect(unterbefehle(), <String>[
          'find-certificate',
          'trust-settings-export',
          'remove-trusted-cert',
          'verify-cert',
        ]);
      });

      test('eine nicht vertraute Stelle gleichen Namens bleibt unberührt '
          '(keine unnötige Frage)', () async {
        vertraut(<String>[aktuell]);

        expect(
          await trustLocalCa(caPfad, run: fake.runner, home: home),
          isTrue,
        );
        expect(unterbefehle(), isNot(contains('remove-trusted-cert')));
      });

      test('ohne Vertrauenseinstellungen (Export scheitert) wird nichts '
          'entzogen', () async {
        vertraut(const <String>[], exitCode: 1);

        expect(
          await trustLocalCa(caPfad, run: fake.runner, home: home),
          isTrue,
        );
        expect(unterbefehle(), isNot(contains('remove-trusted-cert')));
      });

      test('lässt sich das alte Vertrauen nicht entziehen, wird die neue '
          'Stelle nicht eingetragen', () async {
        vertraut(<String>[alt]);
        fake.exitCodes['remove-trusted-cert'] = 1;

        expect(
          await trustLocalCa(caPfad, run: fake.runner, home: home),
          isFalse,
        );
        expect(unterbefehle(), isNot(contains('add-trusted-cert')));
      });
    });
  });

  group('untrustLocalCa', () {
    test('ruft remove-trusted-cert mit der Stelle', () async {
      expect(await untrustLocalCa(caPfad, run: fake.runner), isTrue);
      expect(fake.calls.single.executable, _security);
      expect(fake.calls.single.arguments, <String>[
        'remove-trusted-cert',
        caPfad,
      ]);
    });

    test('Fehlschlag oder fehlendes security: false', () async {
      fake.exitCodes['remove-trusted-cert'] = 1;
      expect(await untrustLocalCa(caPfad, run: fake.runner), isFalse);
      fake.missing.add(_security);
      expect(await untrustLocalCa(caPfad, run: fake.runner), isFalse);
    });
  });

  test('loginKeychainPath', () {
    expect(
      loginKeychainPath('/Users/beispiel'),
      '/Users/beispiel/Library/Keychains/login.keychain-db',
    );
  });
}

/// Ein erfundenes PEM: richtiges Format, beliebiger Inhalt.
String _pem(String inhalt) {
  final b64 = base64.encode(utf8.encode(inhalt.padRight(80, '.')));
  final zeilen = <String>[
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return '-----BEGIN CERTIFICATE-----\n${zeilen.join('\n')}\n'
      '-----END CERTIFICATE-----\n';
}

List<int> _der(String pem) => base64.decode(
  pem
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), ''),
);

String _sha1(String pem) => sha1.convert(_der(pem)).toString().toUpperCase();

String _sha256(String pem) =>
    sha256.convert(_der(pem)).toString().toUpperCase();

/// Ein Treffer von `security find-certificate -a -Z -p`, so wie macOS ihn
/// schreibt.
String _fundstelle(String pem) =>
    'SHA-256 hash: ${_sha256(pem)}\nSHA-1 hash: ${_sha1(pem)}\n$pem';

/// Ausgabe von `security trust-settings-export` (gekürzt auf das, was zählt).
String _vertrauensliste(Iterable<String> sha1s) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>trustList</key>
	<dict>
${sha1s.map((h) => '''
		<key>$h</key>
		<dict>
			<key>issuerName</key>
			<data>
			MCQxIjAgBgNVBAMMGUthc3NlbmVjayBDb25uZWN0IChsb2thbCk=
			</data>
			<key>trustSettings</key>
			<array/>
		</dict>
''').join()}	</dict>
	<key>trustVersion</key>
	<integer>1</integer>
</dict>
</plist>
''';
