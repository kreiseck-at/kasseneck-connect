@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Der Deinstallierer für macOS. Ausgeführt wird er im Test nie (er braucht
/// root und fasst den Schlüsselbund an); geprüft werden die Funktionen seines
/// markierten Abschnitts mit echtem `awk`, `openssl` und `mktemp`, dazu die
/// Aufrufe im Text. `security` und `tccutil` laufen nie: statt
/// `as_console_user` setzt der Test die Attrappe [_attrappe] ein.
final File _skript = File(
  p.join(Directory.current.path, 'tool', 'pkg', 'macos', 'uninstall.sh'),
);

const String _name = 'Kasseneck Connect (lokal)';
const String _security = '/usr/bin/security';

/// Die bash, die das Skript am Mac wirklich bekommt (dort 3.2) — `sudo bash`
/// und das Admin-Fenster finden beide `/bin/bash`.
final String _bash = File('/bin/bash').existsSync() ? '/bin/bash' : 'bash';

/// Attrappe für `as_console_user`: schreibt jeden Aufruf mit (Argumente durch
/// 0x1F getrennt, ein Aufruf je Zeile), legt jede übergebene Datei samt
/// Rechten (Datei und Ordner) unter `$GESEHEN/<aufruf>-<argument>` ab, hält
/// je Aufruf den ganzen Arbeitsort fest (`$GESEHEN/baum-<aufruf>`) und
/// antwortet mit den Vorgaben aus der Umgebung des Tests.
/// `trust-settings-export` schreibt `$EXPORT_DATEI` in die Zieldatei (wenn
/// gesetzt) und `$EXPORT_MELDUNG` nach stderr.
const String _attrappe = r'''
as_console_user() {
  local n i=0 arg
  n=$(wc -l < "$AUFRUFE" | tr -d ' ')
  cp -R "$BASIS" "$GESEHEN/baum-$n"
  for arg in "$@"; do
    printf '%s\037' "$arg" >> "$AUFRUFE"
    if [ -f "$arg" ]; then
      cp "$arg" "$GESEHEN/$n-$i"
      ls -ld "$arg" | cut -c1-10 > "$GESEHEN/$n-$i.datei"
      ls -ld "$(dirname "$arg")" | cut -c1-10 > "$GESEHEN/$n-$i.ordner"
    fi
    i=$((i + 1))
  done
  printf '\n' >> "$AUFRUFE"
  case "$2" in
    find-certificate)
      case " $* " in
        *" -p "*) cat "$FIND_PEM" ;;
        *) cat "$FIND" ;;
      esac
      return "$FIND_EXIT" ;;
    remove-trusted-cert) return "$REMOVE_EXIT" ;;
    verify-cert) return "$VERIFY_EXIT" ;;
    delete-certificate) return "$DELETE_EXIT" ;;
    trust-settings-export)
      if [ -n "$EXPORT_DATEI" ]; then cp "$EXPORT_DATEI" "$3"; fi
      if [ -n "$EXPORT_MELDUNG" ]; then echo "$EXPORT_MELDUNG" >&2; fi
      return "$EXPORT_EXIT" ;;
    reset) return "$TCC_EXIT" ;;
  esac
  return 99
}
''';

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

  /// Führt [befehl] in einer bash aus, die nur den markierten Abschnitt des
  /// Skripts kennt — mit [attrappe] zusätzlich [_attrappe] statt der echten
  /// Sitzung des Benutzers, gesteuert über [umgebung].
  Future<ProcessResult> mitAuswahl(
    String befehl, {
    String? eingabe,
    bool attrappe = false,
    Map<String, String> umgebung = const <String, String>{},
  }) async {
    final start = text.indexOf('# >>> Schlüsselbund und Bluetooth');
    final ende = text.indexOf('# <<< Schlüsselbund und Bluetooth');
    expect(start, greaterThan(0));
    expect(ende, greaterThan(start));
    final auswahl = File(p.join(temp.path, 'auswahl.sh'))
      ..writeAsStringSync(
        'CA_NAME="$_name"\n'
        '${text.substring(start, ende)}\n'
        '${attrappe ? _attrappe : ''}',
      );
    final prozess = await Process.start(_bash, <String>[
      '-c',
      'source "\$1"; $befehl',
      'bash',
      auswahl.path,
    ], environment: umgebung);
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

  group('mit Attrappe statt der Sitzung des Benutzers', () {
    late Directory basis;
    late Directory tmpdir;
    late Directory gesehen;
    late File protokoll;
    late String tls;
    late String keychain;

    setUp(() {
      basis = Directory(p.join(temp.path, 'basis'))..createSync();
      // Steht für den TMPDIR von root: 0700, der Benutzer käme nicht hinein.
      tmpdir = Directory(p.join(temp.path, 'tmpdir'))..createSync();
      Process.runSync('chmod', <String>['700', tmpdir.path]);
      gesehen = Directory(p.join(temp.path, 'gesehen'))..createSync();
      protokoll = File(p.join(temp.path, 'aufrufe'))..writeAsStringSync('');
      tls = p.join(temp.path, 'tls');
      keychain = p.join(temp.path, 'login.keychain-db');
    });

    /// Lässt [befehl] mit der Attrappe laufen. [treffer] und [trefferPem]
    /// schreibt `find-certificate` ohne bzw. mit `-p`. `trust-settings-export`
    /// liefert die Liste [vertraut] (SHA-1, `null`: keine Datei) samt
    /// [exportMeldung] und [exportExit]; Standard ist eine Liste mit einem
    /// fremden Eintrag. Die übrigen Werte sind die Exitcodes der jeweiligen
    /// Aufrufe.
    Future<ProcessResult> lauf(
      String befehl, {
      String treffer = '',
      String trefferPem = '',
      int find = 0,
      int remove = 0,
      int verify = 1,
      int delete = 0,
      int tcc = 0,
      List<String>? vertraut = const <String>[
        'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
      ],
      String exportMeldung = '',
      int exportExit = 0,
    }) {
      final ohnePem = File(p.join(temp.path, 'find'))
        ..writeAsStringSync(treffer);
      final mitPem = File(p.join(temp.path, 'find-pem'))
        ..writeAsStringSync(trefferPem);
      final liste = File(p.join(temp.path, 'vertrauen.plist'))
        ..writeAsStringSync(_vertrauensliste(vertraut ?? const <String>[]));
      return mitAuswahl(
        befehl,
        attrappe: true,
        umgebung: <String, String>{
          'TMPDIR': tmpdir.path,
          'BASIS': basis.path,
          'AUFRUFE': protokoll.path,
          'GESEHEN': gesehen.path,
          'FIND': ohnePem.path,
          'FIND_PEM': mitPem.path,
          'FIND_EXIT': '$find',
          'REMOVE_EXIT': '$remove',
          'VERIFY_EXIT': '$verify',
          'DELETE_EXIT': '$delete',
          'TCC_EXIT': '$tcc',
          'EXPORT_DATEI': vertraut == null ? '' : liste.path,
          'EXPORT_MELDUNG': exportMeldung,
          'EXPORT_EXIT': '$exportExit',
        },
      );
    }

    String untrust() =>
        'untrust_local_ca "$keychain" "$tls" "${basis.path}" "\$(id -un)"; '
        r'echo "CA_TRUST_LEFT=$CA_TRUST_LEFT"';

    /// Alle Dateien, die je unter dem Arbeitsort lagen, solange die Attrappe
    /// lief — samt allem, was ihr übergeben wurde.
    Iterable<List<int>> allesGesehene() => gesehen
        .listSync(recursive: true)
        .whereType<File>()
        .map((datei) => datei.readAsBytesSync());

    /// Alle Aufrufe der Attrappe, je Aufruf die Argumente.
    List<List<String>> aufrufe() => protokoll
        .readAsStringSync()
        .split('\n')
        .where((zeile) => zeile.isNotEmpty)
        .map((zeile) => zeile.split('\x1f')..removeLast())
        .toList();

    /// Inhalt der Datei, die Aufruf [n] als Argument [i] bekam — so, wie sie
    /// in dem Moment war.
    String inhalt(int n, int i) =>
        File(p.join(gesehen.path, '$n-$i')).readAsStringSync();

    /// Rechte (`ls -ld`) dieser Datei und ihres Ordners in dem Moment.
    (String, String) rechte(int n, int i) => (
      File(p.join(gesehen.path, '$n-$i.datei')).readAsStringSync().trim(),
      File(p.join(gesehen.path, '$n-$i.ordner')).readAsStringSync().trim(),
    );

    Future<TlsFiles> echteZertifikate() => LocalCertificates(
      directory: temp,
      run: Process.run,
      log: AgentLog(Directory(p.join(temp.path, 'logs'))),
    ).ensure();

    /// Der Fall vom Gerät: die aktuelle Stelle steht im Schlüsselbund, dazu
    /// eine ältere mit genau dem Namen und ein fremdes Zertifikat.
    Future<({ProcessResult r, String stelle, String sha1, String aelter})>
    geraetefall({
      int remove = 0,
      int verify = 1,
      List<String>? vertraut = const <String>[
        'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
      ],
      String exportMeldung = '',
      int exportExit = 0,
    }) async {
      await echteZertifikate();
      final stelle = File(p.join(tls, 'ca-cert.pem')).readAsStringSync();
      final fingerabdruck = _sha1(stelle);
      final aelter = _pem('ältere Stelle');
      final r = await lauf(
        untrust(),
        treffer: <String>[
          _treffer(fingerabdruck, _name),
          _treffer('B' * 40, _name),
          _treffer('C' * 40, 'Fremd'),
        ].join(),
        trefferPem: <String>[
          _trefferPem(fingerabdruck, stelle),
          _trefferPem('B' * 40, aelter),
          _trefferPem('C' * 40, _pem('fremd')),
        ].join(),
        remove: remove,
        verify: verify,
        vertraut: vertraut,
        exportMeldung: exportMeldung,
        exportExit: exportExit,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return (r: r, stelle: stelle, sha1: fingerabdruck, aelter: aelter);
    }

    test(
      'die aktuelle Stelle verliert ihr Vertrauen über ihre eigene Datei, '
      'auch wenn sie im Schlüsselbund steht; gelöscht wird nach der Prüfung',
      () async {
        final fall = await geraetefall();
        final a = aufrufe();
        expect(a.map((aufruf) => aufruf[1]).toList(), <String>[
          'find-certificate',
          'find-certificate',
          'remove-trusted-cert',
          'remove-trusted-cert',
          'verify-cert',
          'trust-settings-export',
          'delete-certificate',
        ]);
        expect(a.map((aufruf) => aufruf.first).toSet(), <String>{_security});

        // Die aktuelle Stelle verliert ihr Vertrauen genau einmal, und zwar
        // über ihre eigene Datei — nie über die Kopie aus dem Schlüsselbund.
        expect(
          <String>[
            for (final (n, aufruf) in a.indexed)
              if (aufruf[1] == 'remove-trusted-cert' &&
                  _gleich(_der(inhalt(n, 2)), _der(fall.stelle)))
                p.basename(aufruf[2]),
          ],
          <String>['ca-cert.pem'],
        );

        // Die ältere Stelle über ihr Zertifikat aus dem Schlüsselbund ...
        expect(p.basename(a[2][2]), '${'B' * 40}.pem');
        expect(inhalt(2, 2), fall.aelter);

        // ... die aktuelle über ihre eigene Datei, nie über die Kopie aus
        // dem Schlüsselbund.
        final arbeit = p.dirname(a[3][2]);
        expect(a[3], <String>[
          _security,
          'remove-trusted-cert',
          p.join(arbeit, 'ca-cert.pem'),
        ]);
        expect(_der(inhalt(3, 2)), _der(fall.stelle));

        // Dieselbe Prüfung wie der Agent, mit den Dateien aus tls/.
        expect(a[4], <String>[
          _security,
          'verify-cert',
          '-c',
          p.join(arbeit, 'server-cert.pem'),
          '-c',
          p.join(arbeit, 'ca-cert.pem'),
          '-p',
          'ssl',
          '-L',
          '-q',
        ]);
        expect(
          _der(inhalt(4, 3)),
          _der(File(p.join(tls, 'server-cert.pem')).readAsStringSync()),
        );
        expect(_der(inhalt(4, 5)), _der(fall.stelle));

        // Die Vertrauenseinstellungen des Benutzers, in einen Ordner, der
        // ihm gehört.
        expect(a[5], <String>[
          _security,
          'trust-settings-export',
          p.join(arbeit, 'export', 'vertrauen.plist'),
        ]);

        expect(a[6], <String>[
          _security,
          'delete-certificate',
          '-Z',
          fall.sha1,
          keychain,
        ]);

        final ausgabe = '${fall.r.stdout}';
        expect(
          ausgabe,
          contains(
            'Vertrauen in die lokale Zertifizierungsstelle entzogen '
            '(nachgeprüft).',
          ),
        );
        expect(
          ausgabe,
          contains(
            'Zertifikat der Stelle aus dem Anmelde-Schlüsselbund entfernt.',
          ),
        );
        expect(
          ausgabe,
          contains(
            'Ältere Stellen von Connect im Schlüsselbund: 1, Vertrauen '
            'entzogen bei 1.',
          ),
        );
        expect(ausgabe, isNot(contains('WARNUNG')));
        expect(ausgabe, contains('CA_TRUST_LEFT=0'));
      },
      skip: ohneOpenssl,
    );

    test('der Benutzer kann jede Datei lesen: Arbeitsordner am übergebenen Ort '
        '(nicht im TMPDIR von root), danach wieder weg', () async {
      await geraetefall();
      final a = aufrufe();
      var geprueft = 0;
      for (final (n, aufruf) in a.indexed) {
        if (aufruf[1] == 'find-certificate') continue;
        for (final (i, argument) in aufruf.indexed) {
          if (!argument.endsWith('.pem')) continue;
          expect(
            p.isWithin(basis.path, argument),
            isTrue,
            reason: '$argument liegt nicht unter ${basis.path}',
          );
          expect(
            p.basename(p.dirname(argument)) == 'aeltere'
                ? p.basename(p.dirname(p.dirname(argument)))
                : p.basename(p.dirname(argument)),
            startsWith('kasseneck-connect-deinstall.'),
          );
          expect(rechte(n, i), ('-rw-r--r--', 'drwxr-xr-x'), reason: argument);
          geprueft++;
        }
      }
      expect(geprueft, 4);
      expect(basis.listSync(), isEmpty);
      expect(tmpdir.listSync(), isEmpty);
    }, skip: ohneOpenssl);

    test('der Arbeitsordner geht auch nach einem Fehler und bei Abbruch '
        'weg', () async {
      for (final (ende, code) in <(String, int)>[
        ('exit 3', 3),
        (r'kill -TERM $$; echo weiter', 130),
      ]) {
        final r = await mitAuswahl(
          'make_cert_dir "${basis.path}"; touch "\$CERT_DIR/x"; '
          'echo "\$CERT_DIR"; $ende',
        );
        expect(r.exitCode, code, reason: '${r.stderr}');
        final ordner = '${r.stdout}'.trim().split('\n').first;
        expect(p.isWithin(basis.path, ordner), isTrue, reason: ordner);
        expect(Directory(ordner).existsSync(), isFalse, reason: ende);
        expect('${r.stdout}', isNot(contains('weiter')));
      }
    });

    test(
      'ein verwaister Vertrauenseintrag (Stelle nicht mehr im Schlüsselbund) '
      'wird über die eigene Datei abgeräumt',
      () async {
        await echteZertifikate();
        final stelle = File(p.join(tls, 'ca-cert.pem')).readAsStringSync();
        // Kein Treffer: `find-certificate` endet mit 44, löschen ebenso.
        final r = await lauf(untrust(), find: 44, delete: 44);
        expect(r.exitCode, 0, reason: '${r.stderr}');

        final a = aufrufe();
        expect(a.map((aufruf) => aufruf[1]).toList(), <String>[
          'find-certificate',
          'remove-trusted-cert',
          'verify-cert',
          'trust-settings-export',
          'delete-certificate',
        ]);
        expect(p.basename(a[1][2]), 'ca-cert.pem');
        expect(_der(inhalt(1, 2)), _der(stelle));
        final ausgabe = '${r.stdout}';
        expect(ausgabe, contains('entzogen (nachgeprüft).'));
        // Nichts gelöscht, also auch keine Erfolgszeile dafür.
        expect(ausgabe, isNot(contains('Schlüsselbund entfernt')));
        expect(ausgabe, isNot(contains('Ältere Stellen')));
      },
      skip: ohneOpenssl,
    );

    test('wird der Stelle danach noch vertraut, bleibt ihr Zertifikat stehen, '
        'und die Ausgabe nennt den Befehl', () async {
      final fall = await geraetefall(remove: 1, verify: 0);
      final a = aufrufe();
      expect(a.map((aufruf) => aufruf[1]).toList(), <String>[
        'find-certificate',
        'find-certificate',
        'remove-trusted-cert',
        'remove-trusted-cert',
        'verify-cert',
      ]);
      final ausgabe = '${fall.r.stdout}';
      expect(
        ausgabe,
        contains(
          'WARNUNG: Der lokalen Zertifizierungsstelle wird weiterhin '
          'vertraut',
        ),
      );
      expect(
        ausgabe,
        contains(
          'security remove-trusted-cert "${p.join(tls, 'ca-cert.pem')}"',
        ),
      );
      expect(ausgabe, isNot(contains('nachgeprüft')));
      expect(ausgabe, isNot(contains('Schlüsselbund entfernt')));
      expect(ausgabe, contains('CA_TRUST_LEFT=1'));
    }, skip: ohneOpenssl);

    test('fehlt server-cert.pem, gilt die Stelle als nicht prüfbar: kein '
        'Löschen, Warnung', () async {
      await echteZertifikate();
      File(p.join(tls, 'server-cert.pem')).deleteSync();
      // Ein `verify-cert` sagte hier „nicht vertraut“ — es darf gar nicht
      // erst laufen.
      final r = await lauf(untrust(), find: 44, verify: 1);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      expect(aufrufe().map((aufruf) => aufruf[1]).toList(), <String>[
        'find-certificate',
        'remove-trusted-cert',
      ]);
      final ausgabe = '${r.stdout}';
      expect(
        ausgabe,
        contains(
          'WARNUNG: Dass der lokalen Zertifizierungsstelle nicht mehr '
          'vertraut wird,',
        ),
      );
      expect(
        ausgabe,
        contains('(server-cert.pem fehlt oder ist kein Zertifikat)'),
      );
      expect(
        ausgabe,
        contains(
          'security remove-trusted-cert "${p.join(tls, 'ca-cert.pem')}"',
        ),
      );
      expect(ausgabe, isNot(contains('nachgeprüft')));
      expect(ausgabe, contains('CA_TRUST_LEFT=1'));
    }, skip: ohneOpenssl);

    /// Prüft: kein `delete-certificate`, eine Warnung mit [grund] und dem
    /// Befehl für Handarbeit, `CA_TRUST_LEFT=1`.
    void ohneLoeschen(ProcessResult r, String grund) {
      expect(
        aufrufe().map((aufruf) => aufruf[1]),
        isNot(contains('delete-certificate')),
      );
      final ausgabe = '${r.stdout}';
      expect(
        ausgabe,
        contains(
          'WARNUNG: Dass der lokalen Zertifizierungsstelle nicht mehr '
          'vertraut wird,',
        ),
      );
      expect(ausgabe, contains('($grund)'));
      expect(
        ausgabe,
        contains(
          'security remove-trusted-cert "${p.join(tls, 'ca-cert.pem')}"',
        ),
      );
      expect(ausgabe, isNot(contains('nachgeprüft')));
      expect(ausgabe, contains('CA_TRUST_LEFT=1'));
    }

    test('abgelaufenes Serverzertifikat: kein Beleg, auch wenn verify-cert '
        'scheitert — kein Löschen, Warnung', () async {
      await echteZertifikate();
      File(
        p.join(tls, 'server-cert.pem'),
      ).writeAsStringSync(await _abgelaufen(temp));
      final r = await lauf(untrust(), find: 44, verify: 1);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      // verify-cert scheiterte hier ohnehin; es läuft gar nicht erst.
      expect(aufrufe().map((aufruf) => aufruf[1]).toList(), <String>[
        'find-certificate',
        'remove-trusted-cert',
      ]);
      ohneLoeschen(r, 'das Serverzertifikat ist abgelaufen');
    }, skip: ohneOpenssl);

    test('kennen die Vertrauenseinstellungen die Stelle noch, wird nicht '
        'gelöscht', () async {
      await echteZertifikate();
      final stelle = File(p.join(tls, 'ca-cert.pem')).readAsStringSync();
      // Klein geschrieben: auch so zählt der Eintrag.
      final r = await lauf(
        untrust(),
        find: 44,
        verify: 1,
        vertraut: <String>['D' * 40, _sha1(stelle).toLowerCase()],
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(aufrufe().map((aufruf) => aufruf[1]).toList(), <String>[
        'find-certificate',
        'remove-trusted-cert',
        'verify-cert',
        'trust-settings-export',
      ]);
      ohneLoeschen(
        r,
        'die Vertrauenseinstellungen kennen sie noch oder ließen sich nicht '
        'lesen',
      );
    }, skip: ohneOpenssl);

    test(
      'meldet der Export, dass es keine Vertrauenseinstellungen gibt, und ist '
      'alles andere belegt, wird gelöscht',
      () async {
        for (final meldung in <String>[
          'SecTrustSettingsCreateExternalRepresentation: No Trust Settings '
              'were found.',
          'SecTrustSettingsCreateExternalRepresentation: Es wurden keine '
              'Vertrauenseinstellungen gefunden.',
        ]) {
          protokoll.writeAsStringSync('');
          final fall = await geraetefall(
            vertraut: null,
            exportMeldung: meldung,
            exportExit: 1,
          );
          final a = aufrufe();
          expect(a.map((aufruf) => aufruf[1]).last, 'delete-certificate');
          expect(a.last, <String>[
            _security,
            'delete-certificate',
            '-Z',
            fall.sha1,
            keychain,
          ]);
          expect('${fall.r.stdout}', contains('entzogen (nachgeprüft).'));
          expect('${fall.r.stdout}', contains('CA_TRUST_LEFT=0'));
        }
      },
      skip: ohneOpenssl,
    );

    test('scheitert der Export anders (oder liefert keine Liste), wird nicht '
        'gelöscht', () async {
      await echteZertifikate();
      for (final (meldung, code, liste) in <(String, int, List<String>?)>[
        ('Error (-61) writing vertrauen.plist.', 1, null),
        ('sudo: unknown user', 1, null),
        ('', 0, null),
      ]) {
        protokoll.writeAsStringSync('');
        final r = await lauf(
          untrust(),
          find: 44,
          verify: 1,
          vertraut: liste,
          exportMeldung: meldung,
          exportExit: code,
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(
          aufrufe().map((aufruf) => aufruf[1]).last,
          'trust-settings-export',
          reason: meldung,
        );
        ohneLoeschen(
          r,
          'die Vertrauenseinstellungen kennen sie noch oder ließen sich '
          'nicht lesen',
        );
      }
    }, skip: ohneOpenssl);

    test(
      'Kopien nur als gelesenes Zertifikat: ein Symlink auf eine andere Datei '
      'landet nie im Arbeitsordner',
      () async {
        await echteZertifikate();
        final geheim = File(p.join(temp.path, 'geheim.txt'))
          ..writeAsStringSync('GEHEIM nur für root\n');
        bool sahGeheim() => allesGesehene().any(
          (bytes) =>
              utf8.decode(bytes, allowMalformed: true).contains('GEHEIM'),
        );

        // Die Stelle zeigt auf die fremde Datei.
        final stelle = File(p.join(tls, 'ca-cert.pem'));
        final echteStelle = stelle.readAsStringSync();
        stelle.deleteSync();
        Link(stelle.path).createSync(geheim.path);
        var r = await lauf(untrust(), find: 44, verify: 1);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(sahGeheim(), isFalse);
        expect(aufrufe().map((aufruf) => aufruf[1]).toList(), <String>[
          'find-certificate',
        ]);
        ohneLoeschen(r, 'ca-cert.pem ist kein lesbares Zertifikat');

        // Das Serverzertifikat zeigt auf die fremde Datei.
        Link(stelle.path).deleteSync();
        stelle.writeAsStringSync(echteStelle);
        final server = File(p.join(tls, 'server-cert.pem'))..deleteSync();
        Link(server.path).createSync(geheim.path);
        protokoll.writeAsStringSync('');
        r = await lauf(untrust(), find: 44, verify: 1);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(sahGeheim(), isFalse);
        expect(aufrufe().map((aufruf) => aufruf[1]).toList(), <String>[
          'find-certificate',
          'remove-trusted-cert',
        ]);
        ohneLoeschen(r, 'server-cert.pem fehlt oder ist kein Zertifikat');
      },
      skip: ohneOpenssl,
    );

    group('--purge', () {
      late Directory konfig;
      late Directory draussen;

      setUp(() {
        konfig = Directory(p.join(temp.path, 'KasseneckConnect'));
        for (final datei in <String>[
          'config.json',
          'logs/connect.log',
          'tls/ca-cert.pem',
          'tls/ca-key.pem',
          'tls/server-cert.pem',
          'tls/server-key.pem',
        ]) {
          File(p.join(konfig.path, datei))
            ..createSync(recursive: true)
            ..writeAsStringSync(datei);
        }
        // Was draußen liegt, darf root über keinen Symlink erreichen.
        draussen = Directory(p.join(temp.path, 'draussen'))..createSync();
        File(p.join(draussen.path, 'wichtig')).writeAsStringSync('bleibt');
        Link(p.join(konfig.path, 'tls', 'umweg')).createSync(draussen.path);
        Link(p.join(konfig.path, 'umweg')).createSync(draussen.path);
      });

      List<String> uebrig() =>
          konfig
              .listSync(recursive: true, followLinks: false)
              .map((e) => p.relative(e.path, from: konfig.path))
              .toList()
            ..sort();

      test(
        'ohne Beleg bleibt nur tls/ca-cert.pem, und die Ausgabe sagt es',
        () async {
          final r = await mitAuswahl('purge_config "${konfig.path}" 1');
          expect(r.exitCode, 0, reason: '${r.stderr}');
          expect(uebrig(), <String>['tls', p.join('tls', 'ca-cert.pem')]);
          expect(
            File(p.join(konfig.path, 'tls', 'ca-cert.pem')).readAsStringSync(),
            'tls/ca-cert.pem',
          );
          expect(
            '${r.stdout}',
            contains('Konfiguration entfernt bis auf tls/ca-cert.pem'),
          );
          expect('${r.stdout}', contains('"${konfig.path}"'));
          expect(
            File(p.join(draussen.path, 'wichtig')).readAsStringSync(),
            'bleibt',
          );
        },
      );

      test('mit Beleg geht alles', () async {
        final r = await mitAuswahl('purge_config "${konfig.path}" 0');
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(konfig.existsSync(), isFalse);
        expect('${r.stdout}', contains('Konfiguration, Zertifikate und Log'));
        expect(
          File(p.join(draussen.path, 'wichtig')).readAsStringSync(),
          'bleibt',
        );
      });

      test('ist tls/ ein Symlink, geht nur der Symlink', () async {
        Directory(p.join(konfig.path, 'tls')).deleteSync(recursive: true);
        Link(p.join(konfig.path, 'tls')).createSync(draussen.path);
        final r = await mitAuswahl('purge_config "${konfig.path}" 1');
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(uebrig(), isEmpty);
        expect(draussen.listSync().map((e) => p.basename(e.path)), <String>[
          'wichtig',
        ]);
      });
    });

    test('ohne Arbeitsordner wird nichts angefasst, aber gewarnt', () async {
      Directory(tls).createSync();
      File(p.join(tls, 'ca-cert.pem')).writeAsStringSync(_pem('Stelle'));
      final fehlt = p.join(temp.path, 'gibt-es-nicht');
      final r = await lauf(
        'untrust_local_ca "$keychain" "$tls" "$fehlt"; '
        r'echo "CA_TRUST_LEFT=$CA_TRUST_LEFT"',
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(aufrufe(), isEmpty);
      final ausgabe = '${r.stdout}';
      expect(ausgabe, contains('WARNUNG: Kein Arbeitsordner'));
      expect(
        ausgabe,
        contains(
          'security remove-trusted-cert "${p.join(tls, 'ca-cert.pem')}"',
        ),
      );
      expect(ausgabe, contains('CA_TRUST_LEFT=1'));
    });

    test('ohne ca-cert.pem nur die älteren Stellen, ehrlich gezählt', () async {
      final r = await lauf(
        untrust(),
        treffer: _treffer('B' * 40, _name),
        trefferPem: _trefferPem('B' * 40, _pem('ältere Stelle')),
        remove: 1,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(aufrufe().map((aufruf) => aufruf[1]).toList(), <String>[
        'find-certificate',
        'find-certificate',
        'remove-trusted-cert',
      ]);
      final ausgabe = '${r.stdout}';
      expect(
        ausgabe,
        contains(
          'Ältere Stellen von Connect im Schlüsselbund: 1, Vertrauen '
          'entzogen bei 0.',
        ),
      );
      expect(ausgabe, contains('Keine lokale Zertifizierungsstelle'));
      expect(ausgabe, contains('CA_TRUST_LEFT=0'));
    });

    test('Bluetooth-Freigabe: Erfolg nur, wenn tccutil mit 0 endet', () async {
      final ok = await lauf('reset_bluetooth at.kasseneck.connect');
      expect(aufrufe(), <List<String>>[
        <String>[
          '/usr/bin/tccutil',
          'reset',
          'BluetoothAlways',
          'at.kasseneck.connect',
        ],
      ]);
      expect('${ok.stdout}', contains('Bluetooth-Freigabe zurückgesetzt.'));
      expect('${ok.stdout}', isNot(contains('WARNUNG')));

      final nein = await lauf('reset_bluetooth at.kasseneck.connect', tcc: 1);
      expect('${nein.stdout}', isNot(contains('zurückgesetzt.')));
      expect(
        '${nein.stdout}',
        contains('WARNUNG: Die Bluetooth-Freigabe ließ sich nicht'),
      );
    });
  });

  group('Aufrufe im Text', () {
    List<String> befehle() =>
        zeilen.map((z) => z.trim()).where((z) => !z.startsWith('#')).toList();

    test('gelöscht wird nur per Fingerabdruck der eigenen ca-cert.pem', () {
      final loeschen = zeilen
          .where((z) => z.contains('delete-certificate'))
          .toList();
      expect(loeschen, hasLength(1), reason: loeschen.join('\n'));
      final aufruf = loeschen.single;
      expect(aufruf, contains(r'delete-certificate -Z "$ca_sha1"'));
      expect(aufruf, isNot(contains(' -c ')));
      expect(aufruf, isNot(contains(' -t')));

      // ca_sha1 kommt nur aus der eigenen Datei (als gelesenes Zertifikat).
      expect(befehle().where((z) => z.contains('ca_sha1=')).toList(), <String>[
        r'local ca_copy="" ca_sha1="" wanted older pem found=0 removed=0',
        r'ca_sha1="$(sha1_of "$ca_copy")"',
      ]);
      expect(
        text,
        contains(
          r'if [ -f "$ca" ] && cert_copy "$ca" "$CERT_DIR/ca-cert.pem"; then',
        ),
      );
      expect(
        text,
        contains(
          r'local keychain="$1" ca="$2/ca-cert.pem" '
          r'server="$2/server-cert.pem"',
        ),
      );
      expect(
        text,
        contains(
          r'"$CONSOLE_HOME/Library/Application Support/KasseneckConnect/tls" \',
        ),
      );
    });

    test('Vertrauen wird nur über die genaue Bezeichnung oder die eigene '
        'Datei entzogen', () {
      final entziehen = befehle()
          .where((z) => z.contains('remove-trusted-cert'))
          .where((z) => !z.startsWith('echo '))
          .toList();
      expect(entziehen, <String>[
        r'if as_console_user /usr/bin/security remove-trusted-cert "$pem" \',
        r'as_console_user /usr/bin/security remove-trusted-cert "$ca_copy" \',
      ]);
      // Die PEMs stammen aus der genauen Auswahl, ohne die aktuelle Stelle.
      expect(text, contains(r'| exact_label_hashes "$CA_NAME")"'));
      expect(text, contains(r'older="$(without_hash "$wanted" "$ca_sha1")"'));
      expect(text, contains(r'| write_pems "$CERT_DIR/aeltere" "$older"'));
    });

    test('der Arbeitsordner liegt unter /private/tmp, nie im TMPDIR', () {
      final mktemp = befehle().where((z) => z.contains('mktemp')).toList();
      expect(mktemp, <String>[
        r'CERT_DIR="$(/usr/bin/mktemp -d "$1/kasseneck-connect-deinstall.XXXXXX")" \',
      ]);
      final aufruf = zeilen.indexWhere(
        (z) => z.trim().startsWith('untrust_local_ca "'),
      );
      expect(aufruf, greaterThan(0));
      expect(zeilen[aufruf + 2].trim(), r'/private/tmp "$CONSOLE_USER"');
      expect(text, contains(r'reset_bluetooth "$BUNDLE_ID"'));
    });

    test('Programme der Benutzersitzung nur mit festem Pfad', () {
      // Keine Umgebungsvariable entscheidet, was als root (bzw. als
      // Benutzer) startet.
      final aufrufe = befehle()
          .where((z) => z.contains('as_console_user '))
          .toList();
      expect(aufrufe, isNotEmpty);
      for (final aufruf in aufrufe) {
        expect(
          aufruf,
          matches(RegExp(r'as_console_user /usr/bin/(security|tccutil) ')),
        );
      }
    });

    test(
      '--purge geht über purge_config und behält ohne Beleg ca-cert.pem',
      () {
        final aufruf = zeilen.indexWhere(
          (z) => z.trim().startsWith('purge_config "'),
        );
        expect(aufruf, greaterThan(0));
        expect(
          zeilen[aufruf].trim(),
          r'purge_config "$CONSOLE_HOME/Library/Application Support/'
          r'KasseneckConnect" \',
        );
        expect(zeilen[aufruf + 1].trim(), r'"$CA_TRUST_LEFT"');
        // Gelöscht wird die Konfiguration nur dort.
        expect(
          befehle().where(
            (z) => z.contains('KasseneckConnect"') && z.contains('rm '),
          ),
          isEmpty,
        );
      },
    );

    test('aus dem Ordner des Benutzers kopiert root nur gelesene '
        'Zertifikate', () {
      expect(
        befehle().where((z) => RegExp(r'(^|[\s/])cp ').hasMatch(z)),
        isEmpty,
      );
      expect(
        text,
        contains(
          r'if /usr/bin/openssl x509 -in "$1" -out "$2" >/dev/null 2>&1; then',
        ),
      );
      // Beide Kopien gehen über cert_copy.
      expect(text, contains(r'cert_copy "$ca" "$CERT_DIR/ca-cert.pem"'));
      expect(
        text,
        contains(r'cert_copy "$server" "$CERT_DIR/server-cert.pem"'),
      );
    });

    test('Pfade und Namen stehen immer in Anführungszeichen', () {
      final variable = RegExp(
        r'\$(CA_CERT|KEYCHAIN|PEM|CERT_DIR|CA_NAME|CONSOLE_HOME|WANTED|CA_SHA1|'
        r'keychain|ca|server|pem|ca_sha1|ca_copy|wanted|older|dir|export|'
        r'output|reason)\b',
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

/// DER eines PEM-Zertifikats.
List<int> _der(String pem) => base64.decode(
  pem
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), ''),
);

bool _gleich(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

/// SHA-1 über das DER eines PEM-Zertifikats, wie `security` ihn schreibt.
String _sha1(String pem) => sha1.convert(_der(pem)).toString().toUpperCase();

/// Ausgabe von `security trust-settings-export` (gekürzt auf das, was zählt):
/// je SHA-1 ein Eintrag in `trustList`.
String _vertrauensliste(Iterable<String> sha1s) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>trustList</key>
	<dict>
${sha1s.map((h) => '\t\t<key>$h</key>\n\t\t<dict>\n\t\t\t<key>trustSettings</key>\n\t\t\t<array/>\n\t\t</dict>\n').join()}\t</dict>
	<key>trustVersion</key>
	<integer>1</integer>
</dict>
</plist>
''';

/// Ein abgelaufenes Zertifikat (gültig 1.–2.1.2000) als PEM. `openssl ca`
/// nimmt feste Daten an — LibreSSL 3.3 wie OpenSSL 3; `-days` nicht.
Future<String> _abgelaufen(Directory temp) async {
  final ort = Directory(p.join(temp.path, 'abgelaufen'))..createSync();
  String pfad(String name) => p.join(ort.path, name);
  Directory(pfad('neu')).createSync();
  File(pfad('index.txt')).writeAsStringSync('');
  File(pfad('serial')).writeAsStringSync('01\n');
  File(pfad('ca.cnf')).writeAsStringSync('''
[ca]
default_ca = alt
[alt]
database = ${pfad('index.txt')}
new_certs_dir = ${pfad('neu')}
serial = ${pfad('serial')}
default_md = sha256
policy = frei
unique_subject = no
[frei]
commonName = supplied
[req]
distinguished_name = dn
[dn]
''');
  for (final argumente in <List<String>>[
    <String>[
      'ecparam',
      '-name',
      'prime256v1',
      '-genkey',
      '-noout',
      '-out',
      pfad('k.pem'),
    ],
    <String>[
      'req',
      '-new',
      '-key',
      pfad('k.pem'),
      '-subj',
      '/CN=127.0.0.1',
      '-config',
      pfad('ca.cnf'),
      '-out',
      pfad('r.pem'),
    ],
    <String>[
      'ca',
      '-batch',
      '-config',
      pfad('ca.cnf'),
      '-selfsign',
      '-keyfile',
      pfad('k.pem'),
      '-in',
      pfad('r.pem'),
      '-startdate',
      '20000101000000Z',
      '-enddate',
      '20000102000000Z',
      '-out',
      pfad('c.pem'),
    ],
  ]) {
    final r = await Process.run('/usr/bin/openssl', argumente);
    expect(r.exitCode, 0, reason: '${argumente.first}: ${r.stderr}');
  }
  final pem = File(pfad('c.pem')).readAsStringSync();
  return pem.substring(pem.indexOf('-----BEGIN CERTIFICATE-----'));
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
