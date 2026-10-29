@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

/// Pfad, unter dem die Attrappe `openssl` erwartet.
const String _openssl = '/usr/bin/openssl';

/// Feste Uhr der Attrappen-Tests.
final DateTime _jetzt = DateTime.utc(2026, 10, 29, 12);

void main() {
  group('Attrappe', () {
    late Directory temp;
    late Directory tls;
    late AgentLog log;
    late _OpensslNachbau nachbau;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('connect-tls-');
      tls = Directory(p.join(temp.path, 'tls'));
      log = AgentLog(Directory(p.join(temp.path, 'logs')));
      nachbau = _OpensslNachbau();
    });

    tearDown(() => temp.deleteSync(recursive: true));

    LocalCertificates zertifikate() => LocalCertificates(
      directory: temp,
      run: nachbau.runner,
      log: log,
      clock: () => _jetzt,
    );

    String inTls(String name) => p.join(tls.path, name);

    List<RecordedCall> opensslAufrufe() =>
        nachbau.aufrufe.where((c) => c.executable == _openssl).toList();

    test('ensure legt Stelle und Server an, wenn nichts da ist', () async {
      final dateien = await zertifikate().ensure();

      expect(dateien.caCreated, isTrue);
      expect(dateien.caCertPath, inTls('ca-cert.pem'));
      expect(dateien.serverCertPath, inTls('server-cert.pem'));
      expect(dateien.serverKeyPath, inTls('server-key.pem'));
      expect(dateien.serverNotAfter, _jetzt.add(const Duration(days: 397)));
      for (final name in <String>[
        'ca-cert.pem',
        'ca-key.pem',
        'server-cert.pem',
        'server-key.pem',
      ]) {
        expect(File(inTls(name)).existsSync(), isTrue, reason: name);
      }

      // Die Stelle ist mit ihrem eigenen Schlüssel unterschrieben, der Server
      // von der Stelle.
      final stelle = _Zert.lies(inTls('ca-cert.pem'))!;
      final server = _Zert.lies(inTls('server-cert.pem'))!;
      expect(stelle.schluessel, _schluesselIn(inTls('ca-key.pem')));
      expect(stelle.aussteller, stelle.schluessel);
      expect(server.schluessel, _schluesselIn(inTls('server-key.pem')));
      expect(server.aussteller, stelle.schluessel);

      final aufrufe = nachbau.aufrufe;
      expect(aufrufe.map((c) => c.executable).toList(), <String>[
        'chmod',
        'chmod',
        _openssl,
        _openssl,
        'chmod',
        _openssl,
        _openssl,
        _openssl,
        _openssl,
        _openssl,
      ]);
      expect(aufrufe[0].arguments, <String>['700', tls.path]);

      // Erst die leere Datei auf 0600, dann schreibt openssl hinein.
      final tmp = matches(RegExp(r'\.tmp$'));
      final stellenSchluessel = aufrufe[2].arguments.last;
      expect(aufrufe[1].arguments, <String>['600', stellenSchluessel]);
      expect(aufrufe[2].arguments, <Object>[
        'ecparam',
        '-name',
        'prime256v1',
        '-param_enc',
        'named_curve',
        '-genkey',
        '-noout',
        '-out',
        allOf(startsWith('${inTls('ca-key.pem')}.'), tmp),
      ]);

      final stellenZert = aufrufe[3].arguments[6];
      final konfiguration = aufrufe[3].arguments[15];
      expect(aufrufe[3].arguments, <Object>[
        'req',
        '-new',
        '-x509',
        '-key',
        stellenSchluessel,
        '-out',
        allOf(startsWith('${inTls('ca-cert.pem')}.'), tmp),
        '-days',
        '3650',
        '-sha256',
        '-subj',
        '/CN=Kasseneck Connect (lokal)',
        '-set_serial',
        matches(RegExp(r'^0x[4-7][0-9a-f]{31}$')),
        '-config',
        konfiguration,
        '-extensions',
        'v3_ca',
      ]);
      // Die Erweiterungsdatei liegt im Temp-Verzeichnis, nie neben den
      // Schlüsseln.
      expect(p.isWithin(Directory.systemTemp.path, konfiguration), isTrue);
      expect(p.isWithin(temp.path, konfiguration), isFalse);

      final serverSchluessel = aufrufe[5].arguments.last;
      expect(aufrufe[4].arguments, <String>['600', serverSchluessel]);
      expect(aufrufe[5].arguments.take(8), aufrufe[2].arguments.take(8));
      expect(
        serverSchluessel,
        allOf(startsWith('${inTls('server-key.pem')}.'), tmp),
      );

      final antrag = aufrufe[6].arguments[5];
      expect(aufrufe[6].arguments, <String>[
        'req',
        '-new',
        '-key',
        serverSchluessel,
        '-out',
        antrag,
        '-sha256',
        '-subj',
        '/CN=localhost',
        '-config',
        konfiguration,
      ]);
      expect(p.dirname(antrag), p.dirname(konfiguration));

      final serverZert = aufrufe[7].arguments.last;
      expect(aufrufe[7].arguments, <Object>[
        'x509',
        '-req',
        '-in',
        antrag,
        '-CA',
        stellenZert,
        '-CAkey',
        stellenSchluessel,
        '-set_serial',
        allOf(
          matches(RegExp(r'^0x[4-7][0-9a-f]{31}$')),
          isNot(aufrufe[3].arguments[13]),
        ),
        '-days',
        '397',
        '-sha256',
        '-extfile',
        konfiguration,
        '-extensions',
        'v3_server',
        '-out',
        allOf(startsWith('${inTls('server-cert.pem')}.'), tmp),
      ]);
      expect(aufrufe[8].arguments, <String>[
        'x509',
        '-noout',
        '-enddate',
        '-pubkey',
        '-in',
        serverZert,
      ]);
      expect(aufrufe[9].arguments, <String>[
        'verify',
        '-purpose',
        'sslserver',
        '-CAfile',
        stellenZert,
        serverZert,
      ]);

      // Temp-Verzeichnis samt Erweiterungsdatei und Antrag ist weg, im
      // Ablageordner liegt kein Rest.
      expect(Directory(p.dirname(konfiguration)).existsSync(), isFalse);
      expect(_reste(tls), isEmpty);
    });

    test('Erweiterungsdatei trägt die Werte der Spec wörtlich', () async {
      await zertifikate().ensure();
      final konfiguration = nachbau.konfiguration!;
      final abschnitte = _abschnitte(konfiguration);

      expect(abschnitte['v3_ca'], <String>[
        'basicConstraints = critical, CA:TRUE, pathlen:0',
        'keyUsage = critical, keyCertSign, cRLSign',
        'nameConstraints = critical, '
            'permitted;IP:127.0.0.1/255.255.255.255, permitted;DNS:localhost',
        'subjectKeyIdentifier = hash',
        'authorityKeyIdentifier = keyid:always',
      ]);
      expect(abschnitte['v3_server'], <String>[
        'basicConstraints = critical, CA:FALSE',
        'keyUsage = critical, digitalSignature',
        'extendedKeyUsage = serverAuth',
        'subjectAltName = IP:127.0.0.1, DNS:localhost',
        'subjectKeyIdentifier = hash',
        'authorityKeyIdentifier = keyid:always',
      ]);
      // Kein `prompt = no`: LibreSSL nähme sonst den Namen aus der Datei statt
      // aus `-subj`.
      expect(konfiguration, isNot(contains('prompt')));
    });

    test('gültiges Serverzertifikat bleibt unangetastet', () async {
      _bestand(tls, serverBis: DateTime.utc(2027, 3, 7, 9, 15, 4));
      final vorher = _inhalte(tls);

      final dateien = await zertifikate().ensure();

      expect(dateien.caCreated, isFalse);
      expect(dateien.serverNotAfter, DateTime.utc(2027, 3, 7, 9, 15, 4));
      expect(dateien.caCertPath, inTls('ca-cert.pem'));
      expect(_inhalte(tls), vorher);
      // Auch ohne Neuanlage: Ordner und Schlüssel werden jedes Mal wieder
      // eingeschränkt.
      expect(nachbau.aufrufe.map((c) => c.line).toList(), <String>[
        'chmod 700 ${tls.path}',
        'chmod 600 ${inTls('ca-key.pem')}',
        'chmod 600 ${inTls('server-key.pem')}',
        '$_openssl x509 -noout -enddate -pubkey -in ${inTls('ca-cert.pem')}',
        '$_openssl pkey -in ${inTls('ca-key.pem')} -pubout',
        '$_openssl x509 -noout -enddate -pubkey -in ${inTls('server-cert.pem')}',
        '$_openssl pkey -in ${inTls('server-key.pem')} -pubout',
        '$_openssl verify -purpose sslserver -CAfile ${inTls('ca-cert.pem')} '
            '${inTls('server-cert.pem')}',
      ]);
    });

    test(
      '29 Tage vor Ablauf wird nur das Serverzertifikat erneuert, caCreated false',
      () async {
        _bestand(tls, serverBis: _jetzt.add(const Duration(days: 29)));
        final vorher = _inhalte(tls);

        final dateien = await zertifikate().ensure();

        expect(dateien.caCreated, isFalse);
        expect(dateien.serverNotAfter, _jetzt.add(const Duration(days: 397)));
        final nachher = _inhalte(tls);
        expect(nachher['ca-cert.pem'], vorher['ca-cert.pem']);
        expect(nachher['ca-key.pem'], vorher['ca-key.pem']);
        expect(nachher['server-cert.pem'], isNot(vorher['server-cert.pem']));
        expect(nachher['server-key.pem'], isNot(vorher['server-key.pem']));
        expect(_Zert.lies(inTls('server-cert.pem'))!.aussteller, 1);

        final openssl = opensslAufrufe();
        expect(
          openssl.where((c) => c.arguments.first == 'ecparam'),
          hasLength(1),
        );
        expect(openssl.where((c) => c.arguments.contains('-x509')), isEmpty);
        final unterschrift = openssl.singleWhere(
          (c) => c.arguments.contains('-req'),
        );
        final a = unterschrift.arguments;
        expect(a[a.indexOf('-CA') + 1], inTls('ca-cert.pem'));
        expect(a[a.indexOf('-CAkey') + 1], inTls('ca-key.pem'));
        expect(_reste(tls), isEmpty);
      },
    );

    test('genau 30 Tage vor Ablauf bleibt das Serverzertifikat', () async {
      _bestand(tls, serverBis: _jetzt.add(const Duration(days: 30)));
      final vorher = _inhalte(tls);

      final dateien = await zertifikate().ensure();

      expect(dateien.caCreated, isFalse);
      expect(_inhalte(tls), vorher);
    });

    test('Schlüsseldateien haben Modus 0600', () async {
      await zertifikate().ensure();

      final aufrufe = nachbau.aufrufe;
      final schluessel = aufrufe
          .where((c) => c.arguments.first == 'ecparam')
          .map((c) => c.arguments.last)
          .toList();
      expect(schluessel, hasLength(2));
      for (final datei in schluessel) {
        final chmod = aufrufe.indexWhere(
          (c) =>
              c.executable == 'chmod' &&
              c.arguments.length == 2 &&
              c.arguments[0] == '600' &&
              c.arguments[1] == datei,
        );
        expect(chmod, isNot(-1), reason: 'chmod 600 für $datei');
        // Eingeschränkt, bevor openssl den Schlüssel hineinschreibt — die
        // Datei stand da schon, aber leer.
        final erzeugt = aufrufe.indexWhere(
          (c) => c.arguments.first == 'ecparam' && c.arguments.last == datei,
        );
        expect(chmod, lessThan(erzeugt), reason: datei);
        expect(nachbau.beiChmod[datei], '', reason: datei);
      }
      // Die eingeschränkten Temp-Dateien sind die, die jetzt als Schlüssel
      // dastehen.
      expect(File(schluessel[0]).existsSync(), isFalse);
      expect(File(schluessel[1]).existsSync(), isFalse);
      expect(_schluesselIn(inTls('ca-key.pem')), 100);
      expect(_schluesselIn(inTls('server-key.pem')), 101);
    }, testOn: '!windows');

    test('Stelle läuft in 29 Tagen ab: neue Stelle und neuer Server', () async {
      _bestand(
        tls,
        stelleBis: _jetzt.add(const Duration(days: 29)),
        serverBis: DateTime.utc(2027, 3, 7, 9, 15, 4),
      );
      final vorher = _inhalte(tls);

      final dateien = await zertifikate().ensure();

      expect(dateien.caCreated, isTrue);
      final nachher = _inhalte(tls);
      for (final name in vorher.keys) {
        expect(nachher[name], isNot(vorher[name]), reason: name);
      }
      final stelle = _Zert.lies(inTls('ca-cert.pem'))!;
      expect(stelle.bis, _jetzt.add(const Duration(days: 3650)));
      expect(
        _Zert.lies(inTls('server-cert.pem'))!.aussteller,
        stelle.schluessel,
      );
    });

    group('ungültiger Bestand', () {
      Future<TlsFiles> nachSchaden(void Function() schaden) async {
        _bestand(tls, serverBis: DateTime.utc(2027, 3, 7, 9, 15, 4));
        schaden();
        return zertifikate().ensure();
      }

      void stelleUnveraendert() {
        expect(File(inTls('ca-key.pem')).readAsStringSync(), 'SCHLUESSEL 1');
        expect(_Zert.lies(inTls('ca-cert.pem'))!.schluessel, 1);
      }

      void serverNeuVonStelle(int stelle) {
        final server = _Zert.lies(inTls('server-cert.pem'))!;
        expect(server.aussteller, stelle);
        expect(server.schluessel, _schluesselIn(inTls('server-key.pem')));
        expect(server.bis, _jetzt.add(const Duration(days: 397)));
      }

      test(
        'Serverzertifikat einer fremden Stelle wird neu ausgestellt',
        () async {
          final dateien = await nachSchaden(
            () => File(
              inTls('server-cert.pem'),
            ).writeAsStringSync(_Zert(2, 9, DateTime.utc(2027, 3, 7)).text),
          );
          expect(dateien.caCreated, isFalse);
          stelleUnveraendert();
          serverNeuVonStelle(1);
        },
      );

      test('Serverschlüssel passt nicht zum Zertifikat: neu', () async {
        final dateien = await nachSchaden(
          () => File(inTls('server-key.pem')).writeAsStringSync('SCHLUESSEL 7'),
        );
        expect(dateien.caCreated, isFalse);
        stelleUnveraendert();
        serverNeuVonStelle(1);
      });

      test('unlesbares Serverzertifikat: neu', () async {
        final dateien = await nachSchaden(
          () => File(inTls('server-cert.pem')).writeAsStringSync('kaputt'),
        );
        expect(dateien.caCreated, isFalse);
        stelleUnveraendert();
        serverNeuVonStelle(1);
      });

      test('Serverschlüssel fehlt: neu', () async {
        final dateien = await nachSchaden(
          () => File(inTls('server-key.pem')).deleteSync(),
        );
        expect(dateien.caCreated, isFalse);
        stelleUnveraendert();
        serverNeuVonStelle(1);
      });

      test('Schlüssel der Stelle fehlt: neue Stelle', () async {
        final dateien = await nachSchaden(
          () => File(inTls('ca-key.pem')).deleteSync(),
        );
        expect(dateien.caCreated, isTrue);
        final stelle = _Zert.lies(inTls('ca-cert.pem'))!;
        expect(stelle.schluessel, _schluesselIn(inTls('ca-key.pem')));
        serverNeuVonStelle(stelle.schluessel);
      });

      test('Schlüssel der Stelle passt nicht: neue Stelle', () async {
        final dateien = await nachSchaden(
          () => File(inTls('ca-key.pem')).writeAsStringSync('SCHLUESSEL 8'),
        );
        expect(dateien.caCreated, isTrue);
        final stelle = _Zert.lies(inTls('ca-cert.pem'))!;
        expect(stelle.schluessel, _schluesselIn(inTls('ca-key.pem')));
        serverNeuVonStelle(stelle.schluessel);
      });

      test('unlesbare Stelle: neue Stelle', () async {
        final dateien = await nachSchaden(
          () => File(inTls('ca-cert.pem')).writeAsStringSync('kaputt'),
        );
        expect(dateien.caCreated, isTrue);
        serverNeuVonStelle(_Zert.lies(inTls('ca-cert.pem'))!.schluessel);
      });

      // Die zwei Stände, die ein Abbruch beim Festschreiben hinterlassen
      // kann: neuer Schlüssel steht schon, das Zertifikat dazu noch nicht.
      test('Abbruch nach dem Schlüssel der Stelle: neue Stelle', () async {
        final dateien = await nachSchaden(() {
          File(inTls('server-cert.pem')).deleteSync();
          File(inTls('ca-cert.pem')).deleteSync();
          File(inTls('ca-key.pem')).writeAsStringSync('SCHLUESSEL 3');
        });
        expect(dateien.caCreated, isTrue);
        final stelle = _Zert.lies(inTls('ca-cert.pem'))!;
        expect(stelle.schluessel, _schluesselIn(inTls('ca-key.pem')));
        serverNeuVonStelle(stelle.schluessel);
      });

      test('Abbruch nach dem Serverschlüssel: nur der Server neu', () async {
        final dateien = await nachSchaden(() {
          File(inTls('server-cert.pem')).deleteSync();
          File(inTls('server-key.pem')).writeAsStringSync('SCHLUESSEL 4');
        });
        expect(dateien.caCreated, isFalse);
        stelleUnveraendert();
        serverNeuVonStelle(1);
      });
    });

    test('renewalDue: unter 30 Tagen ja, ab 30 Tagen nein', () {
      final z = zertifikate();
      expect(z.renewalDue(_jetzt.add(const Duration(days: 31))), isFalse);
      expect(z.renewalDue(_jetzt.add(const Duration(days: 30))), isFalse);
      expect(
        z.renewalDue(_jetzt.add(const Duration(days: 30, seconds: -1))),
        isTrue,
      );
      expect(z.renewalDue(_jetzt.add(const Duration(days: 29))), isTrue);
      expect(z.renewalDue(_jetzt.subtract(const Duration(days: 1))), isTrue);
    });

    test('notAfter wird aus beiden openssl-Schreibweisen gelesen', () {
      expect(
        parseOpensslNotAfter('notAfter=Oct 28 23:09:07 2027 GMT\n'),
        DateTime.utc(2027, 10, 28, 23, 9, 7),
      );
      // Einstelliger Tag mit Leerzeichen aufgefüllt, Schlüssel dahinter.
      expect(
        parseOpensslNotAfter(
          'notAfter=Mar  7 09:15:04 2027 GMT\n'
          '-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n',
        ),
        DateTime.utc(2027, 3, 7, 9, 15, 4),
      );
      expect(
        parseOpensslNotAfter('notAfter=Jan  1 00:00:00.5 2050 GMT\r\n'),
        DateTime.utc(2050),
      );
      expect(parseOpensslNotAfter('notAfter=Foo 28 23:09:07 2027 GMT'), isNull);
      expect(parseOpensslNotAfter('unable to load certificate'), isNull);
      expect(parseOpensslNotAfter(''), isNull);
    });

    test('openssl fehlt: Fehler, keine halben Dateien', () async {
      nachbau.fake.missing.add(_openssl);

      await expectLater(
        zertifikate().ensure(),
        throwsA(isA<TlsCertificateException>()),
      );

      expect(_inhalte(tls), isEmpty);
      expect(_reste(tls), isEmpty);
    });

    test(
      'openssl scheitert beim Unterschreiben: alte Dateien bleiben, keine Reste',
      () async {
        _bestand(tls, serverBis: _jetzt.add(const Duration(days: 10)));
        final vorher = _inhalte(tls);
        nachbau.scheitertBei = (a) => a.contains('-req');

        await expectLater(
          zertifikate().ensure(),
          throwsA(
            isA<TlsCertificateException>().having(
              (e) => e.detail,
              'detail',
              'Attrappe: gescheitert',
            ),
          ),
        );

        expect(_inhalte(tls), vorher);
        expect(_reste(tls), isEmpty);
        final konfiguration = nachbau.aufrufe
            .firstWhere((c) => c.arguments.contains('-config'))
            .arguments
            .last;
        expect(Directory(p.dirname(konfiguration)).existsSync(), isFalse);
      },
    );

    test(
      'neues Serverzertifikat, das nicht verifiziert, wird nicht übernommen',
      () async {
        _bestand(tls, serverBis: _jetzt.add(const Duration(days: 10)));
        final vorher = _inhalte(tls);
        nachbau.scheitertBei = (a) => a.first == 'verify';

        await expectLater(
          zertifikate().ensure(),
          throwsA(isA<TlsCertificateException>()),
        );

        expect(_inhalte(tls), vorher);
        expect(_reste(tls), isEmpty);
      },
    );

    test('liegen gebliebene Temp-Dateien räumt der nächste Lauf weg', () async {
      _bestand(tls, serverBis: DateTime.utc(2027, 3, 7, 9, 15, 4));
      File(
        inTls('server-key.pem.4711.abc.tmp'),
      ).writeAsStringSync('SCHLUESSEL 5');
      File(inTls('ca-cert.pem.4711.def.tmp')).writeAsStringSync('halb');
      final vorher = _inhalte(tls);

      final dateien = await zertifikate().ensure();

      expect(dateien.caCreated, isFalse);
      expect(_reste(tls), isEmpty);
      expect(_inhalte(tls), vorher);
    });

    test('zwei gleichzeitige Aufrufe legen genau eine Stelle an', () async {
      final z = zertifikate();

      final ergebnisse = await Future.wait(<Future<TlsFiles>>[
        z.ensure(),
        z.ensure(),
      ]);

      expect(ergebnisse.map((e) => e.caCreated).toList(), <bool>[true, false]);
      expect(
        opensslAufrufe().where((c) => c.arguments.first == 'ecparam'),
        hasLength(2),
      );
    });

    test('Log nennt die Erneuerung, nie den Schlüssel', () async {
      await zertifikate().ensure();
      final text = log.file.readAsStringSync();

      expect(text, contains('Zertifizierungsstelle'));
      expect(text, contains('Serverzertifikat'));
      expect(text, isNot(contains('SCHLUESSEL')));
    });
  });

  _mitEchtemOpenssl();
}

/// Tests gegen die echten `openssl`-Varianten dieses Rechners.
void _mitEchtemOpenssl() {
  final varianten = _opensslVarianten();
  if (varianten.isEmpty) {
    test('echtes openssl', () {}, skip: 'kein openssl gefunden');
    return;
  }

  for (final openssl in varianten) {
    group('echtes openssl (${_version(openssl)}, $openssl)', () {
      late Directory temp;
      late AgentLog log;
      late TlsFiles dateien;

      Future<ProcessResult> ossl(List<String> argumente) =>
          Process.run(openssl, argumente);

      /// Modus jeder Schlüsseldatei unmittelbar vor und nach `ecparam`
      /// (`null`: die Datei gab es vorher nicht).
      final schluesselModi = <({String datei, int? vorher, int nachher})>[];

      Future<ProcessResult> beobachtet(String programm, List<String> a) async {
        if (a.isEmpty || a.first != 'ecparam') return Process.run(programm, a);
        final datei = File(a.last);
        final vorher = datei.existsSync()
            ? datei.statSync().mode & 0x1ff
            : null;
        final ergebnis = await Process.run(programm, a);
        schluesselModi.add((
          datei: a.last,
          vorher: vorher,
          nachher: datei.statSync().mode & 0x1ff,
        ));
        return ergebnis;
      }

      setUpAll(() async {
        temp = Directory.systemTemp.createTempSync('connect-tls-echt-');
        log = AgentLog(Directory(p.join(temp.path, 'logs')));
        dateien = await LocalCertificates(
          directory: temp,
          run: beobachtet,
          log: log,
          openssl: openssl,
        ).ensure();
      });

      tearDownAll(() => temp.deleteSync(recursive: true));

      test('Erweiterungen stimmen', () async {
        final stelle = await ossl(<String>[
          'x509',
          '-noout',
          '-text',
          '-in',
          dateien.caCertPath,
        ]);
        expect(stelle.exitCode, 0, reason: '${stelle.stderr}');
        final st = '${stelle.stdout}';
        expect(st, contains('Subject: CN=Kasseneck Connect (lokal)'));
        expect(st, contains('prime256v1'));
        expect(st, contains('ecdsa-with-SHA256'));
        expect(st, contains('X509v3 Basic Constraints: critical'));
        expect(st, contains('CA:TRUE, pathlen:0'));
        expect(st, contains('X509v3 Key Usage: critical'));
        expect(st, contains('Certificate Sign, CRL Sign'));
        expect(st, contains('X509v3 Name Constraints: critical'));
        expect(st, contains('IP:127.0.0.1/255.255.255.255'));
        expect(st, contains('DNS:localhost'));
        // Genau diese zwei Namen, nichts sonst.
        expect(RegExp('IP:').allMatches(st), hasLength(1));
        expect(RegExp('DNS:').allMatches(st), hasLength(1));
        expect(st, isNot(contains('Excluded')));

        final server = await ossl(<String>[
          'x509',
          '-noout',
          '-text',
          '-in',
          dateien.serverCertPath,
        ]);
        expect(server.exitCode, 0, reason: '${server.stderr}');
        final se = '${server.stdout}';
        expect(se, contains('Issuer: CN=Kasseneck Connect (lokal)'));
        expect(se, contains('Subject: CN=localhost'));
        expect(se, contains('prime256v1'));
        expect(se, contains('X509v3 Basic Constraints: critical'));
        expect(se, contains('CA:FALSE'));
        expect(se, contains('X509v3 Key Usage: critical'));
        expect(se, contains('Digital Signature'));
        expect(se, isNot(contains('Certificate Sign')));
        expect(se, contains('TLS Web Server Authentication'));
        expect(se, contains('IP Address:127.0.0.1, DNS:localhost'));

        // Laufzeiten: Stelle 3650 Tage, Server 397 Tage.
        final laufzeitStelle = await _laufzeit(ossl, dateien.caCertPath);
        expect(
          laufzeitStelle.bis.difference(laufzeitStelle.von).inSeconds,
          const Duration(days: 3650).inSeconds,
        );
        final laufzeitServer = await _laufzeit(ossl, dateien.serverCertPath);
        expect(
          laufzeitServer.bis.difference(laufzeitServer.von).inSeconds,
          const Duration(days: 397).inSeconds,
        );
        expect(dateien.serverNotAfter, laufzeitServer.bis);
        expect(dateien.caCreated, isTrue);

        // Verschiedene Seriennummern.
        final serien = <String>{
          for (final pfad in <String>[
            dateien.caCertPath,
            dateien.serverCertPath,
          ])
            '${(await ossl(<String>['x509', '-noout', '-serial', '-in', pfad])).stdout}',
        };
        expect(serien, hasLength(2));
      });

      test('Server verifiziert gegen die Stelle', () async {
        final ergebnis = await ossl(<String>[
          'verify',
          '-purpose',
          'sslserver',
          '-CAfile',
          dateien.caCertPath,
          dateien.serverCertPath,
        ]);
        expect(ergebnis.exitCode, 0, reason: '${ergebnis.stderr}');
        expect('${ergebnis.stdout}'.trim(), endsWith(': OK'));
      });

      /// Stellt mit der Stelle ein Zertifikat für [subjectAltName] aus — an
      /// `LocalCertificates` vorbei, so wie es ein Angreifer mit dem
      /// Schlüssel der Stelle täte.
      Future<({String zert, String schluessel})> fremdesZertifikat(
        String ordner,
        String subjectAltName,
      ) async {
        final probe = Directory(p.join(temp.path, ordner))..createSync();
        final ext = File(p.join(probe.path, 'ext.cnf'))
          ..writeAsStringSync(
            '[req]\ndistinguished_name = dn\n\n[dn]\n\n[fremd]\n'
            'basicConstraints = critical, CA:FALSE\n'
            'keyUsage = critical, digitalSignature\n'
            'extendedKeyUsage = serverAuth\n'
            'subjectAltName = $subjectAltName\n',
          );
        final schluessel = p.join(probe.path, 'key.pem');
        final antrag = p.join(probe.path, 'req.csr');
        final zert = p.join(probe.path, 'cert.pem');
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
            '-key',
            schluessel,
            '-out',
            antrag,
            '-subj',
            '/CN=localhost',
            '-config',
            ext.path,
          ],
          <String>[
            'x509',
            '-req',
            '-in',
            antrag,
            '-CA',
            dateien.caCertPath,
            '-CAkey',
            p.join(temp.path, 'tls', 'ca-key.pem'),
            '-set_serial',
            '0x5e1b2c3d4e5f6071',
            '-days',
            '30',
            '-sha256',
            '-extfile',
            ext.path,
            '-extensions',
            'fremd',
            '-out',
            zert,
          ],
        ]) {
          final r = await ossl(schritt);
          expect(r.exitCode, 0, reason: '${schritt.first}: ${r.stderr}');
        }
        return (zert: zert, schluessel: schluessel);
      }

      /// TLS-Server mit [zert]/[schluessel] auf 127.0.0.1, Client vertraut nur
      /// der Stelle. Wirft, wenn der Client die Kette ablehnt.
      Future<void> handschlag(String zert, String schluessel) async {
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          SecurityContext()
            ..useCertificateChain(zert)
            ..usePrivateKey(schluessel),
        );
        server.listen((anfrage) {
          anfrage.response
            ..write('ok')
            ..close();
        }, onError: (Object _) {});
        final client = HttpClient(
          context: SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates(dateien.caCertPath),
        );
        try {
          final anfrage = await client.getUrl(
            Uri.parse('https://127.0.0.1:${server.port}/'),
          );
          final antwort = await anfrage.close();
          expect(antwort.statusCode, 200);
          expect(await antwort.transform(utf8.decoder).join(), 'ok');
        } finally {
          client.close(force: true);
          await server.close(force: true);
        }
      }

      for (final name in <String>['DNS:example.com', 'IP:192.0.2.10']) {
        final kurz = name.substring(name.indexOf(':') + 1);
        test(
          'Zertifikat der Stelle für $kurz fällt durch die Namensbeschränkung',
          () async {
            final fremd = await fremdesZertifikat('probe-$kurz', name);

            final ergebnis = await ossl(<String>[
              'verify',
              '-CAfile',
              dateien.caCertPath,
              fremd.zert,
            ]);
            expect(ergebnis.exitCode, isNot(0));
            expect(
              '${ergebnis.stdout}${ergebnis.stderr}',
              contains('permitted subtree violation'),
            );
          },
        );
      }

      test('Schlüsseldateien haben auf der Platte Modus 0600', () {
        for (final name in <String>['ca-key.pem', 'server-key.pem']) {
          final modus = File(p.join(temp.path, 'tls', name)).statSync().mode;
          expect(
            modus & 0x1ff,
            0x180,
            reason: '$name: ${modus.toRadixString(8)}',
          );
        }
        final ordner = Directory(p.join(temp.path, 'tls')).statSync().mode;
        expect(ordner & 0x1ff, 0x1c0, reason: ordner.toRadixString(8));
      }, testOn: '!windows');

      test(
        'Schlüssel sind nie lesbar für andere: 0600, bevor openssl schreibt',
        () {
          expect(schluesselModi, hasLength(2));
          for (final modus in schluesselModi) {
            final name = p.basename(modus.datei);
            expect(modus.vorher, 0x180, reason: '$name vor ecparam');
            expect(modus.nachher, 0x180, reason: '$name nach ecparam');
          }
        },
        testOn: '!windows',
      );

      Future<void> chmod(String modus, String pfad) async {
        final r = await Process.run('chmod', <String>[modus, pfad]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }

      int modusVon(String pfad) => FileStat.statSync(pfad).mode & 0x1ff;

      test(
        'vorhandener tls-Ordner mit 0755 wird auf 0700 gezogen',
        () async {
          // Stand nach einem Lauf, der zwischen Anlegen und chmod starb.
          final eigen = Directory.systemTemp.createTempSync('connect-tls-ord-');
          addTearDown(() => eigen.deleteSync(recursive: true));
          final tls = Directory(p.join(eigen.path, 'tls'))..createSync();
          await chmod('755', tls.path);
          expect(modusVon(tls.path), 0x1ed);

          final ergebnis = await LocalCertificates(
            directory: eigen,
            run: Process.run,
            log: log,
            openssl: openssl,
          ).ensure();

          expect(ergebnis.caCreated, isTrue);
          expect(modusVon(tls.path), 0x1c0);
          expect(modusVon(p.join(tls.path, 'ca-key.pem')), 0x180);
          expect(modusVon(ergebnis.serverKeyPath), 0x180);
        },
        testOn: '!windows',
      );

      test(
        'vorhandene Schlüssel mit 0644 werden wieder 0600, sonst bleibt alles',
        () async {
          final eigen = Directory.systemTemp.createTempSync('connect-tls-sch-');
          addTearDown(() => eigen.deleteSync(recursive: true));
          LocalCertificates zertifikate() => LocalCertificates(
            directory: eigen,
            run: Process.run,
            log: log,
            openssl: openssl,
          );
          final erster = await zertifikate().ensure();
          final tls = Directory(p.join(eigen.path, 'tls'));
          final caKey = p.join(tls.path, 'ca-key.pem');
          await chmod('755', tls.path);
          await chmod('644', caKey);
          await chmod('644', erster.serverKeyPath);
          final vorher = _inhalte(tls);

          final zweiter = await zertifikate().ensure();

          expect(zweiter.caCreated, isFalse);
          expect(_inhalte(tls), vorher);
          expect(modusVon(tls.path), 0x1c0);
          expect(modusVon(caKey), 0x180);
          expect(modusVon(erster.serverKeyPath), 0x180);
        },
        testOn: '!windows',
      );

      test('zweiter Lauf lässt alles stehen', () async {
        final tls = Directory(p.join(temp.path, 'tls'));
        final vorher = _inhalte(tls);

        final zweiter = await LocalCertificates(
          directory: temp,
          run: Process.run,
          log: log,
          openssl: openssl,
        ).ensure();

        expect(zweiter.caCreated, isFalse);
        expect(zweiter.serverNotAfter, dateien.serverNotAfter);
        expect(_inhalte(tls), vorher);
      });

      // Dart prüft Zertifikate unter macOS mit der Vertrauensprüfung des
      // Systems — derselben, die Safari nutzt. Unter Linux prüft BoringSSL,
      // und dessen alte Prüfung kennt keine IP-Namensbeschränkung: jede
      // Kette dieser Stelle scheitert dort mit „unsupported name constraint
      // type“. Das liegt nicht an den Zertifikaten (OpenSSL und LibreSSL
      // prüfen sie oben), darum laufen die Handschläge nur unter macOS.
      test('macOS nimmt Kette und Schlüssel an (127.0.0.1)', () async {
        await handschlag(dateien.serverCertPath, dateien.serverKeyPath);
      }, testOn: 'mac-os');

      for (final name in <String>['DNS:example.com', 'IP:192.0.2.10']) {
        final kurz = name.substring(name.indexOf(':') + 1);
        test('macOS setzt die Namensbeschränkung durch: $kurz neben 127.0.0.1 '
            'wird abgelehnt', () async {
          // Gleiche Stelle, gleiche Adresse wie oben — nur ein Name mehr,
          // der außerhalb der Beschränkung liegt.
          final fremd = await fremdesZertifikat(
            'mac-$kurz',
            'IP:127.0.0.1, $name',
          );
          await expectLater(
            handschlag(fremd.zert, fremd.schluessel),
            throwsA(isA<HandshakeException>()),
          );
        }, testOn: 'mac-os');
      }

      test('kein Schlüssel im Log', () {
        final text = log.file.readAsStringSync();
        expect(text, contains('Zertifizierungsstelle'));
        expect(text, isNot(contains('PRIVATE KEY')));
        for (final name in <String>['ca-key.pem', 'server-key.pem']) {
          final zeilen = File(
            p.join(temp.path, 'tls', name),
          ).readAsLinesSync().where((z) => !z.startsWith('-----'));
          for (final zeile in zeilen) {
            expect(text, isNot(contains(zeile)), reason: name);
          }
        }
      });
    });
  }

  test('zwei Prozesse gleichzeitig legen genau eine Stelle an', () async {
    final temp = Directory.systemTemp.createTempSync('connect-tls-race-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final worker = p.join(
      Directory.current.path,
      'test',
      'support',
      'tls_worker.dart',
    );
    final start = File(p.join(temp.path, 'los'));

    Future<ProcessResult> spawn(String name) => Process.run(
      Platform.resolvedExecutable,
      <String>['run', worker, temp.path, varianten.first, start.path, name],
      workingDirectory: Directory.current.path,
    );

    final laeufe = <Future<ProcessResult>>[spawn('a'), spawn('b')];
    // Stirbt ein Prozess vor der Startlinie, gibt der Test sie frei, statt
    // bis zum Zeitlimit zu warten — der Fehler steht dann im Ergebnis.
    var einerBeendet = false;
    for (final lauf in laeufe) {
      unawaited(lauf.then((_) => einerBeendet = true));
    }
    // Beide warten an der Startlinie, erst dann geht es gleichzeitig los.
    final bereit = <String>[
      p.join(temp.path, 'bereit-a'),
      p.join(temp.path, 'bereit-b'),
    ];
    while (!einerBeendet && !bereit.every((pfad) => File(pfad).existsSync())) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    start.writeAsStringSync('los');
    final ergebnisse = await Future.wait(laeufe);

    final berichte = <Map<String, Object?>>[];
    for (final ergebnis in ergebnisse) {
      expect(
        ergebnis.exitCode,
        0,
        reason: '${ergebnis.stdout}\n${ergebnis.stderr}',
      );
      final zeile = '${ergebnis.stdout}'.trim().split('\n').last;
      berichte.add(jsonDecode(zeile) as Map<String, Object?>);
    }
    expect(
      berichte.where((b) => b['caCreated'] == true),
      hasLength(1),
      reason: '$berichte',
    );
    final stelle = File(
      p.join(temp.path, 'tls', 'ca-cert.pem'),
    ).readAsStringSync();
    expect(berichte.map((b) => b['ca']).toSet(), <String>{stelle});

    final ergebnis = await Process.run(varianten.first, <String>[
      'verify',
      '-CAfile',
      p.join(temp.path, 'tls', 'ca-cert.pem'),
      p.join(temp.path, 'tls', 'server-cert.pem'),
    ]);
    expect(ergebnis.exitCode, 0, reason: '${ergebnis.stderr}');
  });
}

/// Die `openssl`-Varianten dieses Rechners: `/usr/bin/openssl` (macOS:
/// LibreSSL, so wie beim Kunden) und das erste `openssl` auf dem PATH, sofern
/// es ein anderes Programm ist (OpenSSL 3; in der CI unter Linux meist
/// dasselbe wie `/usr/bin/openssl`).
List<String> _opensslVarianten() {
  final gefunden = <String>[];
  final gesehen = <String>{};
  void nimm(String pfad) {
    final datei = File(pfad);
    if (!datei.existsSync()) return;
    if (gesehen.add(datei.resolveSymbolicLinksSync())) gefunden.add(pfad);
  }

  nimm('/usr/bin/openssl');
  final trenner = Platform.isWindows ? ';' : ':';
  final name = Platform.isWindows ? 'openssl.exe' : 'openssl';
  for (final ordner in (Platform.environment['PATH'] ?? '').split(trenner)) {
    if (ordner.isEmpty) continue;
    final kandidat = p.join(ordner, name);
    if (File(kandidat).existsSync()) {
      nimm(kandidat);
      break;
    }
  }
  return gefunden;
}

String _version(String openssl) {
  try {
    return '${Process.runSync(openssl, <String>['version']).stdout}'.trim();
  } on ProcessException {
    return '?';
  }
}

final RegExp _datumZeile = RegExp(
  r'^(notBefore|notAfter)=([A-Z][a-z]{2}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4}) GMT$',
  multiLine: true,
);

const List<String> _monate = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Beginn und Ende der Gültigkeit, unabhängig vom Code unter Test gelesen.
Future<({DateTime von, DateTime bis})> _laufzeit(
  Future<ProcessResult> Function(List<String>) ossl,
  String zertifikat,
) async {
  final ergebnis = await ossl(<String>[
    'x509',
    '-noout',
    '-startdate',
    '-enddate',
    '-in',
    zertifikat,
  ]);
  final werte = <String, DateTime>{};
  for (final m in _datumZeile.allMatches('${ergebnis.stdout}')) {
    werte[m[1]!] = DateTime.utc(
      int.parse(m[7]!),
      _monate.indexOf(m[2]!) + 1,
      int.parse(m[3]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
  return (von: werte['notBefore']!, bis: werte['notAfter']!);
}

/// Datum in der Schreibweise von `openssl x509 -enddate` (Tag mit Leerzeichen
/// aufgefüllt: `Mar  7 09:15:04 2027 GMT`).
String _opensslDatum(DateTime zeit) {
  final t = zeit.toUtc();
  String zwei(int n) => n.toString().padLeft(2, '0');
  return '${_monate[t.month - 1]} ${t.day.toString().padLeft(2)} '
      '${zwei(t.hour)}:${zwei(t.minute)}:${zwei(t.second)} ${t.year} GMT';
}

/// Ein Zertifikat der Attrappe: wessen Schlüssel, wer unterschrieben hat, bis
/// wann es gilt. Auf der Platte als eine Textzeile.
class _Zert {
  const _Zert(this.schluessel, this.aussteller, this.bis);

  final int schluessel;
  final int aussteller;
  final DateTime bis;

  String get text =>
      'ZERTIFIKAT $schluessel $aussteller ${bis.toUtc().toIso8601String()}';

  static _Zert? lies(String pfad) {
    final datei = File(pfad);
    if (!datei.existsSync()) return null;
    final teile = datei.readAsStringSync().split(' ');
    if (teile.length != 4 || teile[0] != 'ZERTIFIKAT') return null;
    return _Zert(
      int.parse(teile[1]),
      int.parse(teile[2]),
      DateTime.parse(teile[3]),
    );
  }
}

/// Nummer des Attrappen-Schlüssels in [pfad], `null` wenn keiner drinsteht.
int? _schluesselIn(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) return null;
  final teile = datei.readAsStringSync().split(' ');
  if (teile.length != 2 || teile[0] != 'SCHLUESSEL') return null;
  return int.tryParse(teile[1]);
}

/// Spielt `openssl` nach, soweit [LocalCertificates] es aufruft — gerade so
/// genau, dass Schlüsselpaar, Aussteller und Ablaufdatum stimmen. Alles andere
/// (Format, Erweiterungen) prüfen die Tests mit echtem `openssl`.
class _OpensslNachbau {
  _OpensslNachbau() {
    fake.antwort = _antwort;
  }

  final FakeProcessRunner fake = FakeProcessRunner();
  int _naechsterSchluessel = 100;

  /// Inhalt der Erweiterungsdatei beim ersten `req`.
  String? konfiguration;

  /// Aufrufe, auf die das zutrifft, scheitern mit Exitcode 1.
  bool Function(List<String> argumente)? scheitertBei;

  /// Inhalt jeder Datei im Moment ihres `chmod` (`null`: gab es nicht).
  final Map<String, String?> beiChmod = <String, String?>{};

  ProcessRunner get runner => fake.runner;

  List<RecordedCall> get aufrufe => fake.calls;

  static String _wert(List<String> a, String schalter) =>
      a[a.indexOf(schalter) + 1];

  static ProcessResult _ok([String ausgabe = '']) =>
      ProcessResult(42, 0, ausgabe, '');

  static ProcessResult _fehler() =>
      ProcessResult(42, 1, '', 'unable to load certificate');

  static String _oeffentlich(int schluessel) =>
      '-----BEGIN PUBLIC KEY-----\nOEFFENTLICH$schluessel\n'
      '-----END PUBLIC KEY-----\n';

  Future<ProcessResult?> _antwort(String programm, List<String> a) async {
    if (programm == 'chmod') {
      final datei = File(a.last);
      beiChmod[a.last] = datei.existsSync() ? datei.readAsStringSync() : null;
      return null;
    }
    if (programm != _openssl) return null;
    if (scheitertBei?.call(a) ?? false) {
      return ProcessResult(42, 1, '', 'Attrappe: gescheitert');
    }
    switch (a.first) {
      case 'ecparam':
        File(
          _wert(a, '-out'),
        ).writeAsStringSync('SCHLUESSEL ${_naechsterSchluessel++}');
        return _ok();
      case 'req':
        konfiguration ??= File(_wert(a, '-config')).readAsStringSync();
        final schluessel = _schluesselIn(_wert(a, '-key'));
        if (schluessel == null) return _fehler();
        if (a.contains('-x509')) {
          final tage = int.parse(_wert(a, '-days'));
          File(_wert(a, '-out')).writeAsStringSync(
            _Zert(
              schluessel,
              schluessel,
              _jetzt.add(Duration(days: tage)),
            ).text,
          );
        } else {
          File(_wert(a, '-out')).writeAsStringSync('ANTRAG $schluessel');
        }
        return _ok();
      case 'x509':
        if (a.contains('-req')) {
          final antrag = File(_wert(a, '-in')).readAsStringSync().split(' ');
          final stelle = _Zert.lies(_wert(a, '-CA'));
          if (stelle == null ||
              stelle.schluessel != _schluesselIn(_wert(a, '-CAkey'))) {
            return _fehler();
          }
          final tage = int.parse(_wert(a, '-days'));
          File(_wert(a, '-out')).writeAsStringSync(
            _Zert(
              int.parse(antrag[1]),
              stelle.schluessel,
              _jetzt.add(Duration(days: tage)),
            ).text,
          );
          return _ok();
        }
        final zert = _Zert.lies(_wert(a, '-in'));
        if (zert == null) return _fehler();
        return _ok(
          'notAfter=${_opensslDatum(zert.bis)}\n'
          '${_oeffentlich(zert.schluessel)}',
        );
      case 'pkey':
        final schluessel = _schluesselIn(_wert(a, '-in'));
        return schluessel == null ? _fehler() : _ok(_oeffentlich(schluessel));
      case 'verify':
        final stelle = _Zert.lies(_wert(a, '-CAfile'));
        final server = _Zert.lies(a.last);
        final gut =
            stelle != null &&
            server != null &&
            server.aussteller == stelle.schluessel &&
            server.bis.isAfter(_jetzt) &&
            stelle.bis.isAfter(_jetzt);
        return gut
            ? _ok('${a.last}: OK\n')
            : ProcessResult(42, 2, '', 'error 20 at 0 depth lookup');
    }
    return _fehler();
  }
}

/// Legt einen Bestand wie nach einem früheren Lauf an: Stelle mit Schlüssel 1,
/// Server mit Schlüssel 2, unterschrieben von [serverAussteller].
void _bestand(
  Directory tls, {
  DateTime? stelleBis,
  DateTime? serverBis,
  int serverAussteller = 1,
}) {
  tls.createSync(recursive: true);
  File(p.join(tls.path, 'ca-key.pem')).writeAsStringSync('SCHLUESSEL 1');
  File(p.join(tls.path, 'ca-cert.pem')).writeAsStringSync(
    _Zert(1, 1, stelleBis ?? DateTime.utc(2035, 11, 5, 8, 30)).text,
  );
  if (serverBis != null) {
    File(p.join(tls.path, 'server-key.pem')).writeAsStringSync('SCHLUESSEL 2');
    File(
      p.join(tls.path, 'server-cert.pem'),
    ).writeAsStringSync(_Zert(2, serverAussteller, serverBis).text);
  }
}

/// Inhalt der vier Ablagedateien, soweit vorhanden.
Map<String, String> _inhalte(Directory tls) => <String, String>{
  for (final name in <String>[
    'ca-cert.pem',
    'ca-key.pem',
    'server-cert.pem',
    'server-key.pem',
  ])
    if (File(p.join(tls.path, name)).existsSync())
      name: File(p.join(tls.path, name)).readAsStringSync(),
};

/// Liegen gebliebene Temp-Dateien im Ablageordner.
List<String> _reste(Directory tls) => !tls.existsSync()
    ? const <String>[]
    : tls
          .listSync()
          .map((e) => p.basename(e.path))
          .where((name) => name.endsWith('.tmp'))
          .toList();

/// Zeilen je Abschnitt einer openssl-Konfiguration (ohne Leerzeilen).
Map<String, List<String>> _abschnitte(String text) {
  final abschnitte = <String, List<String>>{};
  List<String>? aktuell;
  for (final roh in const LineSplitter().convert(text)) {
    final zeile = roh.trim();
    if (zeile.isEmpty || zeile.startsWith('#')) continue;
    final kopf = RegExp(r'^\[\s*(\S+)\s*\]$').firstMatch(zeile);
    if (kopf != null) {
      aktuell = abschnitte.putIfAbsent(kopf[1]!, () => <String>[]);
    } else {
      aktuell?.add(zeile);
    }
  }
  return abschnitte;
}
