import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

const String _security = '/usr/bin/security';
const String _openssl = '/usr/bin/openssl';

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

      expect(await isLocalCaTrusted(caPfad, start: fake.starter), isTrue);

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
      expect(await isLocalCaTrusted(caPfad, start: fake.starter), isFalse);
    });

    test('ausdrücklicher Pfad des Serverzertifikats', () async {
      final anderes = p.join(temp.path, 'anderes.pem');
      await isLocalCaTrusted(
        caPfad,
        start: fake.starter,
        serverCertPath: anderes,
      );
      expect(fake.calls.single.arguments[2], anderes);
    });

    test('ohne security (kein Mac): nicht vertraut, kein Absturz', () async {
      fake.missing.add(_security);
      expect(await isLocalCaTrusted(caPfad, start: fake.starter), isFalse);
    });

    test(
      'hängt security, gilt es als nicht vertraut — und wird beendet',
      () async {
        fake.antwort = (_, _) => Completer<ProcessResult>().future;
        expect(
          await isLocalCaTrusted(
            caPfad,
            start: fake.starter,
            timeout: const Duration(milliseconds: 50),
          ),
          isFalse,
        );
        // Nicht nur aufgegeben: der Prozess ist beendet, sonst hielte er den
        // Agenten bzw. den Befehl am Leben.
        expect(fake.killed.map((c) => c.arguments.first), <String>[
          'verify-cert',
        ]);
      },
    );
  });

  group('trustLocalCa', () {
    test('trägt die Stelle mit genau diesen Argumenten in den Anmelde-'
        'Schlüsselbund ein', () async {
      expect(
        await trustLocalCa(caPfad, start: fake.starter, home: home),
        isTrue,
      );

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
          await trustLocalCa(caPfad, start: fake.starter, home: home),
          isTrue,
        );
        expect(unterbefehle(), isNot(contains('add-trusted-cert')));
      },
    );

    test('gleiche Stelle schon im Schlüsselbund, aber nicht vertraut: '
        'eintragen', () async {
      fake.exitCodes.remove('find-certificate');
      fake.stdoutOf['find-certificate'] = _fundstelle(aktuell);

      expect(
        await trustLocalCa(caPfad, start: fake.starter, home: home),
        isTrue,
      );
      expect(unterbefehle(), <String>[
        'find-certificate',
        'verify-cert',
        'add-trusted-cert',
      ]);
    });

    test('abgebrochene Frage (Exitcode ≠ 0): false', () async {
      fake.exitCodes['add-trusted-cert'] = 1;
      expect(
        await trustLocalCa(caPfad, start: fake.starter, home: home),
        isFalse,
      );
    });

    test('Frage ohne Antwort: nach der Wartezeit beendet, false', () async {
      fake.antwort = (programm, argumente) =>
          argumente.first == 'add-trusted-cert'
          ? Completer<ProcessResult>().future
          : Future<ProcessResult?>.value();
      expect(
        await trustLocalCa(
          caPfad,
          start: fake.starter,
          home: home,
          promptTimeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
      // Der wartende `security`-Prozess ist beendet — ein Installer, der auf
      // den Befehl wartet, hängt so nicht.
      expect(fake.killed.map((c) => c.arguments.first), <String>[
        'add-trusted-cert',
      ]);
    });

    test('ohne security: false, kein Absturz', () async {
      fake.missing.add(_security);
      expect(
        await trustLocalCa(caPfad, start: fake.starter, home: home),
        isFalse,
      );
    });

    test('unlesbare Stelle: false, kein security-Aufruf', () async {
      File(caPfad).writeAsStringSync('kein Zertifikat');
      expect(
        await trustLocalCa(caPfad, start: fake.starter, home: home),
        isFalse,
      );
      expect(fake.calls, isEmpty);
    });

    group('Stellen gleichen Namens', () {
      final alt = _pem('alte Stelle');

      /// Was `openssl x509 -noout -text` je Zertifikat (PEM) beschreibt;
      /// ohne Eintrag scheitert openssl. `alt` ist eine ältere Stelle von
      /// Connect.
      late Map<String, String> beschreibung;

      setUp(() => beschreibung = <String, String>{alt: _x509Text()});

      /// [im] liegen im Anmelde-Schlüsselbund (Suche nach dem Namen),
      /// [pems] haben Vertrauenseinstellungen: `trust-settings-export`
      /// schreibt sie (Schlüssel: SHA-1) in die Datei, die es bekommt.
      void vertraut(
        Iterable<String> pems, {
        int exitCode = 0,
        List<String>? im,
      }) {
        fake.exitCodes.remove('find-certificate');
        fake.stdoutOf['find-certificate'] = (im ?? <String>[alt, aktuell])
            .map(_fundstelle)
            .join();
        fake.antwort = (programm, argumente) async {
          if (programm == _openssl && argumente.first == 'x509') {
            final text = beschreibung[File(argumente.last).readAsStringSync()];
            return ProcessResult(1, text == null ? 1 : 0, text ?? '', '');
          }
          if (argumente.first != 'trust-settings-export') return null;
          File(
            argumente.last,
          ).writeAsStringSync(_vertrauensliste(pems.map(_sha1)));
          return ProcessResult(1, exitCode, '', '');
        };
      }

      List<RecordedCall> opensslAufrufe() =>
          fake.calls.where((c) => c.executable == _openssl).toList();

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
          await trustLocalCa(caPfad, start: fake.starter, home: home),
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
        // Vorher nachgewiesen, dass es eine Stelle von Connect ist — an
        // derselben Datei.
        final pruefung = opensslAufrufe().single;
        expect(pruefung.arguments.take(4), <String>[
          'x509',
          '-noout',
          '-text',
          '-in',
        ]);
        // Die Datei mit der alten Stelle bleibt nicht liegen.
        final remove = fake.calls.singleWhere(
          (c) => c.arguments.first == 'remove-trusted-cert',
        );
        expect(remove.arguments, hasLength(2));
        expect(remove.arguments.last, pruefung.arguments.last);
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
          await trustLocalCa(caPfad, start: fake.starter, home: home),
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
          await trustLocalCa(caPfad, start: fake.starter, home: home),
          isTrue,
        );
        expect(unterbefehle(), isNot(contains('remove-trusted-cert')));
      });

      test('ohne Vertrauenseinstellungen (Export scheitert) wird nichts '
          'entzogen', () async {
        vertraut(const <String>[], exitCode: 1);

        expect(
          await trustLocalCa(caPfad, start: fake.starter, home: home),
          isTrue,
        );
        expect(unterbefehle(), isNot(contains('remove-trusted-cert')));
      });

      group('ein fremdes Zertifikat behält sein Vertrauen', () {
        final fremd = _pem('fremdes Zertifikat');

        Future<void> bleibt(String text) async {
          beschreibung[fremd] = text;
          vertraut(<String>[fremd], im: <String>[fremd, aktuell]);

          expect(
            await trustLocalCa(caPfad, start: fake.starter, home: home),
            isTrue,
          );
          expect(unterbefehle(), <String>[
            'find-certificate',
            'trust-settings-export',
            'verify-cert',
            'add-trusted-cert',
          ]);
          expect(opensslAufrufe(), hasLength(1));
        }

        test('Bezeichnung enthält den Namen nur', () async {
          // `find-certificate -c` sucht nach Teilen der Bezeichnung.
          const name = 'CN=Meine Kasseneck Connect (lokal) Kopie';
          await bleibt(_x509Text(subject: name, issuer: name));
        });

        test('gleicher Name, aber kein CA:TRUE', () async {
          await bleibt(_x509Text(basic: 'CA:FALSE'));
        });

        test('gleicher Name, aber ohne Namensbeschränkung', () async {
          await bleibt(_x509Text(permitted: null));
        });

        test('gleicher Name, aber andere Namensbeschränkung', () async {
          await bleibt(
            _x509Text(
              permitted: <String>[
                'IP:127.0.0.1/255.255.255.255',
                'DNS:localhost',
                'DNS:example.com',
              ],
            ),
          );
        });

        test('gleicher Name, aber von jemand anderem ausgestellt', () async {
          await bleibt(_x509Text(issuer: 'CN=Andere Stelle'));
        });

        test('lässt sich nicht lesen (openssl scheitert)', () async {
          vertraut(<String>[fremd], im: <String>[fremd, aktuell]);
          expect(
            await trustLocalCa(caPfad, start: fake.starter, home: home),
            isTrue,
          );
          expect(unterbefehle(), isNot(contains('remove-trusted-cert')));
        });
      });

      test('lässt sich das alte Vertrauen nicht entziehen, wird die neue '
          'Stelle nicht eingetragen', () async {
        vertraut(<String>[alt]);
        fake.exitCodes['remove-trusted-cert'] = 1;

        expect(
          await trustLocalCa(caPfad, start: fake.starter, home: home),
          isFalse,
        );
        expect(unterbefehle(), isNot(contains('add-trusted-cert')));
      });
    });
  });

  group('untrustLocalCa', () {
    test('ruft remove-trusted-cert mit der Stelle', () async {
      expect(await untrustLocalCa(caPfad, start: fake.starter), isTrue);
      expect(fake.calls.single.executable, _security);
      expect(fake.calls.single.arguments, <String>[
        'remove-trusted-cert',
        caPfad,
      ]);
    });

    test('Fehlschlag oder fehlendes security: false', () async {
      fake.exitCodes['remove-trusted-cert'] = 1;
      expect(await untrustLocalCa(caPfad, start: fake.starter), isFalse);
      fake.missing.add(_security);
      expect(await untrustLocalCa(caPfad, start: fake.starter), isFalse);
    });
  });

  group('matchesLocalCa', () {
    test('die Stelle in der Schreibweise von LibreSSL und OpenSSL 3', () {
      expect(matchesLocalCa(_x509Text()), isTrue);
      expect(matchesLocalCa(_x509Text().replaceAll('\n', '\r\n')), isTrue);
    });

    test('alles andere nicht', () {
      const name = 'CN=Kasseneck Connect (lokal)';
      for (final (grund, text) in <(String, String)>[
        ('Inhaber anders', _x509Text(subject: 'CN=localhost')),
        ('Inhaber länger', _x509Text(subject: '$name, O=Fremd')),
        ('fremd ausgestellt', _x509Text(issuer: 'CN=Andere Stelle')),
        ('kein CA', _x509Text(basic: 'CA:FALSE')),
        ('ohne Namensbeschränkung', _x509Text(permitted: null)),
        (
          'nur IP',
          _x509Text(permitted: <String>['IP:127.0.0.1/255.255.255.255']),
        ),
        (
          'andere IP',
          _x509Text(
            permitted: <String>['IP:10.0.0.1/255.255.255.255', 'DNS:localhost'],
          ),
        ),
        ('mit Ausschluss', _x509Text(excluded: <String>['DNS:example.com'])),
        ('leer', ''),
      ]) {
        expect(matchesLocalCa(text), isFalse, reason: grund);
      }
    });

    final openssl = File(_openssl).existsSync() ? null : 'kein $_openssl';

    test('echtes openssl: eigene Stelle ja, Serverzertifikat und fremde '
        'gleichnamige Stelle nein', () async {
      final echt = FakeProcessRunner()
        ..echt.addAll(<String>{_openssl, 'chmod'});
      final dateien = await LocalCertificates(
        directory: temp,
        run: echt.runner,
        log: AgentLog(Directory(p.join(temp.path, 'logs'))),
      ).ensure();

      Future<String> text(String pfad) async {
        final r = await Process.run(_openssl, <String>[
          'x509',
          '-noout',
          '-text',
          '-in',
          pfad,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return '${r.stdout}';
      }

      expect(matchesLocalCa(await text(dateien.caCertPath)), isTrue);
      expect(matchesLocalCa(await text(dateien.serverCertPath)), isFalse);

      // Gleicher Name, CA:TRUE, selbst ausgestellt — aber ohne unsere
      // Namensbeschränkung.
      final cnf = File(p.join(temp.path, 'fremd.cnf'))
        ..writeAsStringSync(
          '[req]\ndistinguished_name = dn\n\n[dn]\n\n[fremd]\n'
          'basicConstraints = critical, CA:TRUE\n'
          'keyUsage = critical, keyCertSign\n',
        );
      final schluessel = p.join(temp.path, 'fremd-key.pem');
      final zert = p.join(temp.path, 'fremd-cert.pem');
      for (final schritt in <List<String>>[
        <String>[
          'ecparam',
          '-name',
          'prime256v1',
          '-genkey',
          '-noout',
          '-out',
          schluessel,
        ],
        <String>[
          'req',
          '-new',
          '-x509',
          '-key',
          schluessel,
          '-out',
          zert,
          '-days',
          '30',
          '-subj',
          '/CN=$localCaName',
          '-config',
          cnf.path,
          '-extensions',
          'fremd',
        ],
      ]) {
        final r = await Process.run(_openssl, schritt);
        expect(r.exitCode, 0, reason: '${schritt.first}: ${r.stderr}');
      }
      expect(matchesLocalCa(await text(zert)), isFalse);
    }, skip: openssl);
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

/// Ausgabe von `openssl x509 -noout -text` (gekürzt, Einrückung wie bei
/// LibreSSL und OpenSSL 3). Standard: eine Stelle von Connect.
String _x509Text({
  String subject = 'CN=$localCaName',
  String? issuer,
  String basic = 'CA:TRUE, pathlen:0',
  List<String>? permitted = const <String>[
    'IP:127.0.0.1/255.255.255.255',
    'DNS:localhost',
  ],
  List<String> excluded = const <String>[],
}) {
  final buffer = StringBuffer()
    ..writeln('Certificate:')
    ..writeln('    Data:')
    ..writeln('        Version: 3 (0x2)')
    ..writeln('        Signature Algorithm: ecdsa-with-SHA256')
    ..writeln('        Issuer: ${issuer ?? subject}')
    ..writeln('        Validity')
    ..writeln('            Not Before: Oct 29 12:00:00 2026 GMT')
    ..writeln('            Not After : Oct 26 12:00:00 2036 GMT')
    ..writeln('        Subject: $subject')
    ..writeln('        Subject Public Key Info:')
    ..writeln('            Public Key Algorithm: id-ecPublicKey')
    ..writeln('        X509v3 extensions:')
    ..writeln('            X509v3 Basic Constraints: critical')
    ..writeln('                $basic')
    ..writeln('            X509v3 Key Usage: critical')
    ..writeln('                Certificate Sign, CRL Sign');
  if (permitted != null) {
    buffer
      ..writeln('            X509v3 Name Constraints: critical')
      ..writeln('                Permitted:');
    for (final eintrag in permitted) {
      buffer.writeln('                  $eintrag');
    }
    if (excluded.isNotEmpty) {
      buffer.writeln('                Excluded:');
      for (final eintrag in excluded) {
        buffer.writeln('                  $eintrag');
      }
    }
  }
  buffer
    ..writeln('            X509v3 Subject Key Identifier: ')
    ..writeln('                FC:45:97:E1')
    ..writeln('    Signature Algorithm: ecdsa-with-SHA256');
  return buffer.toString();
}
