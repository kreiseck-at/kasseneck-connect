@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Die Sperren in `tool/release.sh` und `tool/pkg/macos/build_pkg.sh`: ohne
/// Developer-ID-Signatur und Notarisierung geht kein macOS-Paket hinaus.
///
/// Signiert, notarisiert oder hochgeladen wird hier nie. Die Skripte laufen in
/// einer Kopie des Repos, und jedes Werkzeug, das nach außen greift (`gh`,
/// `pkgutil`, `spctl`, `xcrun`, `security`, `codesign`, `notarize_macos.sh`),
/// ist eine Attrappe, die nur mitschreibt und vorgegebene Antworten gibt.
final String _repo = Directory.current.path;

String _datei(List<String> teile) =>
    File(p.joinAll(<String>[_repo, ...teile])).readAsStringSync();

/// `pkgutil --check-signature` eines echten Pakets (1.3.0); die Ablaufdaten
/// ersetzt [_kette] durch feste Abstände zu heute.
final String _pkgutilEcht = _datei(<String>[
  'test',
  'fixtures',
  'update',
  'pkgutil-check-signature-1.3.0.txt',
]);
final String _spctlEcht = _datei(<String>[
  'test',
  'fixtures',
  'update',
  'spctl-install-1.3.0.txt',
]);

/// Datum in der Form von pkgutil („2027-02-01 22:12:15 +0000“), [tage] ab
/// heute.
String _inTagen(int tage) {
  final t = DateTime.now().toUtc().add(Duration(days: tage));
  String zwei(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${zwei(t.month)}-${zwei(t.day)} '
      '${zwei(t.hour)}:${zwei(t.minute)}:${zwei(t.second)} +0000';
}

/// Die echte Ausgabe mit Ablauf des Blatts und der Zwischenstelle in
/// [blattTage] Tagen, die Wurzel in 3000 Tagen.
String _kette({int blattTage = 400}) {
  var nummer = 0;
  return _pkgutilEcht.replaceAllMapped(
    RegExp(r'Expires: [0-9-]+ [0-9:]+ \+0000'),
    (_) => 'Expires: ${_inTagen(nummer++ < 2 ? blattTage : 3000)}',
  );
}

/// Eine bash-Attrappe [name] in [bin]: schreibt den Aufruf nach
/// `$PROTOKOLL` und führt dann [rumpf] aus.
void _attrappe(Directory bin, String name, String rumpf) {
  final datei = File(p.join(bin.path, name))
    ..writeAsStringSync(
      '#!/bin/bash\n'
      'printf \'%s %s\\n\' "$name" "\$*" >> "\$PROTOKOLL"\n'
      '$rumpf\n',
    );
  Process.runSync('chmod', <String>['755', datei.path]);
}

/// Prüft die Attrappen-Antworten; Zustand über Dateien in [steuer].
class _Umgebung {
  _Umgebung(this.wurzel)
    : bin = Directory(p.join(wurzel.path, 'bin'))..createSync(),
      steuer = Directory(p.join(wurzel.path, 'steuer'))..createSync(),
      protokoll = File(p.join(wurzel.path, 'protokoll.txt'))..createSync();

  final Directory wurzel;
  final Directory bin;
  final Directory steuer;
  final File protokoll;

  File steuerdatei(String name) => File(p.join(steuer.path, name));

  Map<String, String> get umgebung => <String, String>{
    'PATH': '${bin.path}:/usr/bin:/bin:/usr/sbin:/sbin',
    'HOME': wurzel.path,
    'PROTOKOLL': protokoll.path,
    'STEUER': steuer.path,
    'LANG': 'C.UTF-8',
  };

  List<String> get aufrufe => protokoll
      .readAsLinesSync()
      .where((zeile) => zeile.trim().isNotEmpty)
      .toList();
}

void main() {
  late Directory temp;
  late _Umgebung u;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-release-');
    u = _Umgebung(temp);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// Führt [befehl] in einer bash aus, die `tool/_common.sh` geladen hat.
  Future<ProcessResult> mitCommon(String befehl) => Process.run(
    'bash',
    <String>[
      '-c',
      'set -euo pipefail; . "\$1"; $befehl',
      'bash',
      p.join(_repo, 'tool', '_common.sh'),
    ],
    environment: u.umgebung,
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  /// pkgutil- und spctl-Attrappen mit den Antworten aus den Steuerdateien.
  void pruefAttrappen() {
    _attrappe(u.bin, 'pkgutil', r'''
cat "$STEUER/pkgutil.txt" 2>/dev/null
exit "$(cat "$STEUER/pkgutil.exit" 2>/dev/null || echo 0)"''');
    _attrappe(u.bin, 'spctl', r'''
cat "$STEUER/spctl.txt" 2>/dev/null
exit "$(cat "$STEUER/spctl.exit" 2>/dev/null || echo 0)"''');
  }

  group('_common.sh: Prüfungen wie im Agenten vor dem Ein-Klick-Update', () {
    setUp(pruefAttrappen);

    Future<int> signiert(String ausgabe, {int exit = 0}) async {
      u.steuerdatei('pkgutil.txt').writeAsStringSync(ausgabe);
      u.steuerdatei('pkgutil.exit').writeAsStringSync('$exit');
      return (await mitCommon('pkg_developer_id_signed x.pkg')).exitCode;
    }

    test(
      'Developer ID Installer des Teams bis Apple Root CA: angenommen',
      () async {
        expect(await signiert(_pkgutilEcht), 0);
      },
    );

    test('unsigniert, fremdes Team, Entwicklerzertifikat oder Kette ohne '
        'Apple Root CA: abgelehnt', () async {
      expect(
        await signiert('Package "x.pkg":\n   Status: no signature\n', exit: 1),
        isNot(0),
      );
      expect(
        await signiert(_pkgutilEcht.replaceAll('6KMT4H4CNE', 'ABCDE12345')),
        isNot(0),
      );
      expect(
        await signiert(
          _pkgutilEcht.replaceAll(
            'signed by a developer certificate issued by Apple for '
                'distribution',
            'signed by a certificate trusted by macOS',
          ),
        ),
        isNot(0),
      );
      expect(
        await signiert(_pkgutilEcht.replaceAll('Apple Root CA', 'Eigene CA')),
        isNot(0),
      );
      expect(
        await signiert(
          _pkgutilEcht.replaceAll(
            'Developer ID Installer',
            'Developer ID Application',
          ),
        ),
        isNot(0),
      );
    });

    test('notarisiert heißt: Gatekeeper sagt „Notarized Developer ID“ des '
        'Teams', () async {
      Future<int> notarisiert(String ausgabe, {int exit = 0}) async {
        u.steuerdatei('spctl.txt').writeAsStringSync(ausgabe);
        u.steuerdatei('spctl.exit').writeAsStringSync('$exit');
        return (await mitCommon('pkg_notarized x.pkg')).exitCode;
      }

      expect(await notarisiert(_spctlEcht), 0);
      expect(
        await notarisiert(
          'x.pkg: rejected\nsource=Unnotarized Developer ID\n',
          exit: 3,
        ),
        isNot(0),
      );
      expect(
        await notarisiert(
          _spctlEcht.replaceAll('Notarized Developer ID', 'Developer ID'),
        ),
        isNot(0),
      );
      expect(
        await notarisiert(_spctlEcht.replaceAll('6KMT4H4CNE', 'ABCDE12345')),
        isNot(0),
      );
    });

    test(
      'Ablauf: Warnung unter 60 Tagen, nicht darüber, laut wenn vorbei',
      () async {
        // Feste Uhr: 09.11.2026, das heutige Zertifikat läuft am 01.02.2027 ab.
        const jetzt = r'"$(utc_epoch "2026-11-09 12:00:00")"';
        final heute = await mitCommon(
          'warn_cert_expiry Blatt "2027-02-01 22:12:15" $jetzt',
        );
        expect(heute.exitCode, 0);
        expect('${heute.stderr}', isEmpty, reason: 'noch 84 Tage');

        final dezember = await mitCommon(
          'warn_cert_expiry Blatt "2027-02-01 22:12:15" '
          '"\$(utc_epoch "2026-12-04 12:00:00")"',
        );
        expect(dezember.exitCode, 0, reason: 'Warnen bricht nie ab');
        expect('${dezember.stderr}', contains('läuft am 2027-02-01 ab'));
        expect('${dezember.stderr}', contains('in 59 Tagen'));

        final vorbei = await mitCommon(
          'warn_cert_expiry Blatt "2026-11-01 00:00:00" $jetzt',
        );
        expect(vorbei.exitCode, 0);
        expect('${vorbei.stderr}', contains('abgelaufen'));
      },
    );

    test('Ablauf aus pkgutil: Blatt und Zwischenstelle zählen, die Wurzel '
        'nicht', () async {
      u.steuerdatei('pkgutil.txt').writeAsStringSync(_kette(blattTage: 30));
      final bald = await mitCommon('warn_pkg_cert_expiry x.pkg');
      expect(bald.exitCode, 0);
      expect(
        '${bald.stderr}',
        contains('„Developer ID Installer: POST NOW e.U. (6KMT4H4CNE)“'),
      );
      expect(
        '${bald.stderr}',
        contains('„Developer ID Certification Authority“'),
      );
      expect('${bald.stderr}', isNot(contains('Apple Root CA')));

      u.steuerdatei('pkgutil.txt').writeAsStringSync(_kette());
      final spaeter = await mitCommon('warn_pkg_cert_expiry x.pkg');
      expect('${spaeter.stderr}', isEmpty);
    });

    test('Ablauf aus der App-Signatur (codesign + openssl)', () async {
      final openssl = Process.runSync('bash', <String>[
        '-c',
        'command -v openssl',
      ]);
      if (openssl.exitCode != 0) {
        markTestSkipped('kein openssl');
        return;
      }
      String zertifikat(String name, int tage) {
        final ziel = p.join(temp.path, '$name.der');
        final r = Process.runSync('openssl', <String>[
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          p.join(temp.path, '$name.key'),
          '-days',
          '$tage',
          '-subj',
          '/CN=Developer ID Application: Muster ($name)',
          '-outform',
          'DER',
          '-out',
          ziel,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return ziel;
      }

      final bald = zertifikat('BALD', 10);
      final lang = zertifikat('LANG', 400);
      // codesign legt die Zertifikate unter <präfix>0, <präfix>1 … ab.
      _attrappe(u.bin, 'codesign', r'''
for arg in "$@"; do
  case "$arg" in
    --extract-certificates=*)
      ziel="${arg#--extract-certificates=}"
      i=0
      for z in $(cat "$STEUER/zertifikate"); do cp "$z" "$ziel$i"; i=$((i + 1)); done ;;
  esac
done''');

      u.steuerdatei('zertifikate').writeAsStringSync('$bald $lang');
      final warnt = await mitCommon('warn_app_cert_expiry "x y.app"');
      expect(warnt.exitCode, 0);
      expect('${warnt.stderr}', contains('Developer ID Application: Muster'));
      expect('${warnt.stderr}', contains('(BALD)'));
      expect('${warnt.stderr}', isNot(contains('(LANG)')));

      u.steuerdatei('zertifikate').writeAsStringSync(lang);
      final still = await mitCommon('warn_app_cert_expiry "x y.app"');
      expect('${still.stderr}', isEmpty);
    });

    test('ein Testbau heißt nie wie eine Auslieferung', () async {
      final r = await mitCommon(
        'testbau_name 1.2.3 macos arm64 pkg; release_name 1.2.3 macos arm64 pkg',
      );
      expect('${r.stdout}'.trim().split('\n'), <String>[
        'KasseneckConnect-1.2.3-macos-arm64-testbau.pkg',
        'KasseneckConnect-1.2.3-macos-arm64.pkg',
      ]);
    });
  });

  group('release.sh', () {
    const version = '9.8.7';
    late Directory kopie;
    late File paket;
    late File gestapelt;

    setUp(() {
      // Eine Kopie mit allem, was release.sh liest; notarize_macos.sh ist
      // eine Attrappe (die echte reicht bei Apple ein).
      kopie = Directory(p.join(temp.path, 'repo'))..createSync();
      Directory(p.join(kopie.path, 'tool')).createSync();
      for (final name in <String>['release.sh', '_common.sh']) {
        File(
          p.join(_repo, 'tool', name),
        ).copySync(p.join(kopie.path, 'tool', name));
      }
      File(
        p.join(kopie.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: kasseneck_connect\nversion: $version\n');
      File(p.join(kopie.path, 'CHANGELOG.md')).writeAsStringSync(
        '# Änderungen\n\n## $version — 2026-11-09\n\n- Probe.\n',
      );
      Directory(p.join(kopie.path, 'build')).createSync();
      paket = File(
        p.join(
          kopie.path,
          'build',
          'KasseneckConnect-$version-macos-arm64.pkg',
        ),
      )..writeAsStringSync('kein echtes Paket');
      gestapelt = u.steuerdatei('gestapelt');

      pruefAttrappen();
      _attrappe(u.bin, 'gh', r'''
case "$1 $2" in
  "release view") exit 1 ;;
  *) exit 0 ;;
esac''');
      _attrappe(u.bin, 'xcrun', r'''
if [ "$1 $2" = "stapler validate" ]; then
  [ -f "$STEUER/gestapelt" ] && exit 0
  exit 65
fi
exit 0''');
      _attrappe(Directory(p.join(kopie.path, 'tool')), 'notarize_macos.sh', r'''
code="$(cat "$STEUER/notar.exit" 2>/dev/null || echo 0)"
[ "$code" = 0 ] && [ -f "$STEUER/notar.stapelt" ] && touch "$STEUER/gestapelt"
exit "$code"''');

      // Standard: richtig signiert, Gatekeeper nimmt es an, noch kein Ticket.
      u.steuerdatei('pkgutil.txt').writeAsStringSync(_kette());
      u.steuerdatei('spctl.txt').writeAsStringSync(_spctlEcht);
    });

    Future<ProcessResult> release({bool probe = false}) => Process.run(
      'bash',
      <String>[
        p.join(kopie.path, 'tool', 'release.sh'),
        if (probe) '--dry-run',
      ],
      environment: u.umgebung,
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    bool hochgeladen() =>
        u.aufrufe.any((zeile) => zeile.startsWith('gh release create'));
    bool eingereicht() =>
        u.aufrufe.any((zeile) => zeile.startsWith('notarize_macos.sh'));

    test('unsigniertes Paket: Abbruch, auch im Probelauf, nichts '
        'hochgeladen', () async {
      u
          .steuerdatei('pkgutil.txt')
          .writeAsStringSync('Package "x.pkg":\n   Status: no signature\n');
      u.steuerdatei('pkgutil.exit').writeAsStringSync('1');

      for (final probe in <bool>[true, false]) {
        final r = await release(probe: probe);
        expect(r.exitCode, 70, reason: 'probe=$probe\n${r.stderr}');
        expect('${r.stderr}', contains('Abbruch:'));
        expect('${r.stderr}', contains('Developer ID Installer'));
        expect('${r.stdout}', isNot(contains('[dry-run] gh release create')));
      }
      expect(hochgeladen(), isFalse);
      expect(eingereicht(), isFalse);
    });

    test('Paket eines fremden Teams: Abbruch', () async {
      u
          .steuerdatei('pkgutil.txt')
          .writeAsStringSync(_kette().replaceAll('6KMT4H4CNE', 'ABCDE12345'));
      final r = await release();
      expect(r.exitCode, 70, reason: '${r.stderr}');
      expect(hochgeladen(), isFalse);
    });

    test('ohne notarytool-Profil: Abbruch statt Veröffentlichung mit '
        'Warnung', () async {
      u.steuerdatei('notar.exit').writeAsStringSync('69');
      final r = await release();
      expect(r.exitCode, 70, reason: '${r.stderr}');
      expect('${r.stderr}', contains('kein notarytool-Profil'));
      expect(eingereicht(), isTrue);
      expect(hochgeladen(), isFalse);
    });

    test('Notarisierung gescheitert: Abbruch', () async {
      u.steuerdatei('notar.exit').writeAsStringSync('70');
      final r = await release();
      expect(r.exitCode, 70, reason: '${r.stderr}');
      expect('${r.stderr}', contains('Notarisierung ist fehlgeschlagen'));
      expect(hochgeladen(), isFalse);
    });

    test('Notarisierung meldet Erfolg, aber kein Ticket: Abbruch', () async {
      final r = await release();
      expect(r.exitCode, 70, reason: '${r.stderr}');
      expect('${r.stderr}', contains('kein Ticket'));
      expect(hochgeladen(), isFalse);
    });

    test('Ticket da, aber Gatekeeper lehnt ab: Abbruch', () async {
      gestapelt.createSync();
      u.steuerdatei('spctl.txt').writeAsStringSync('x.pkg: rejected\n');
      u.steuerdatei('spctl.exit').writeAsStringSync('3');
      final r = await release();
      expect(r.exitCode, 70, reason: '${r.stderr}');
      expect('${r.stderr}', contains('Gatekeeper'));
      expect(hochgeladen(), isFalse);
    });

    test('signiert, nachträglich notarisiert und angenommen: wird '
        'veröffentlicht', () async {
      u.steuerdatei('notar.stapelt').createSync();
      final r = await release();
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(eingereicht(), isTrue);
      final hoch = u.aufrufe.singleWhere(
        (zeile) => zeile.startsWith('gh release create'),
      );
      expect(hoch, contains('build/KasseneckConnect-macos-arm64.pkg'));
      expect(hoch, contains('build/latest.json'));
      expect('${r.stdout}', contains('Geprüft: build/'));
      expect('${r.stderr}', isNot(contains('WARNUNG')));
    });

    test(
      'Probelauf: schon notarisiert – zeigt den Upload, lädt nichts',
      () async {
        gestapelt.createSync();
        final r = await release(probe: true);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect('${r.stdout}', contains('[dry-run] gh release create'));
        expect(hochgeladen(), isFalse);
      },
    );

    test('Probelauf ohne Ticket reicht nichts ein und sagt es', () async {
      final r = await release(probe: true);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect('${r.stdout}', contains('[dry-run] tool/notarize_macos.sh'));
      expect('${r.stderr}', contains('noch nicht notarisiert'));
      expect(eingereicht(), isFalse);
      expect(hochgeladen(), isFalse);
    });

    test(
      'Zertifikat läuft in 30 Tagen ab: Warnung, aber kein Abbruch',
      () async {
        gestapelt.createSync();
        u.steuerdatei('pkgutil.txt').writeAsStringSync(_kette(blattTage: 30));
        final r = await release();
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect('${r.stderr}', contains('WARNUNG: Das Zertifikat'));
        // 29 oder 30: je nachdem, ob seit dem Datum oben eine Sekunde verging.
        expect('${r.stderr}', matches(RegExp(r'in (29|30) Tagen')));
        expect(hochgeladen(), isTrue);
      },
    );

    test('ein Testbau wird nie veröffentlicht', () async {
      paket.renameSync(
        p.join(
          kopie.path,
          'build',
          'KasseneckConnect-$version-macos-arm64-testbau.pkg',
        ),
      );
      final r = await release();
      expect(r.exitCode, 70, reason: '${r.stderr}');
      expect('${r.stderr}', contains('keine einzige Auslieferungsdatei'));
      expect(hochgeladen(), isFalse);
    });
  });

  group('build_pkg.sh', () {
    late Directory kopie;

    setUp(() {
      kopie = Directory(p.join(temp.path, 'repo'))..createSync();
      Directory(
        p.join(kopie.path, 'tool', 'pkg', 'macos'),
      ).createSync(recursive: true);
      File(
        p.join(_repo, 'tool', '_common.sh'),
      ).copySync(p.join(kopie.path, 'tool', '_common.sh'));
      File(
        p.join(_repo, 'tool', 'pkg', 'macos', 'build_pkg.sh'),
      ).copySync(p.join(kopie.path, 'tool', 'pkg', 'macos', 'build_pkg.sh'));
      File(
        p.join(kopie.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: kasseneck_connect\nversion: 9.8.7\n');
      // Ein App-Paket, das nur so aussieht.
      final macos = Directory(
        p.join(
          kopie.path,
          'build',
          'Kasseneck Connect.app',
          'Contents',
          'MacOS',
        ),
      )..createSync(recursive: true);
      for (final name in <String>['kasseneck-connect', 'kasseneck-bluetooth']) {
        final datei = File(p.join(macos.path, name))
          ..writeAsStringSync('#!/bin/sh\necho 9.8.7\n');
        Process.runSync('chmod', <String>['755', datei.path]);
      }
      // Ein Ablagewerkzeug, das kopiert, und eins, das nichts tut.
      _attrappe(u.bin, 'ditto', r'cp -R "$1" "$2"');
      _attrappe(u.bin, 'xattr', 'exit 0');
    });

    Future<ProcessResult> bauen(List<String> argumente) => Process.run(
      'bash',
      <String>[
        p.join(kopie.path, 'tool', 'pkg', 'macos', 'build_pkg.sh'),
        ...argumente,
      ],
      environment: u.umgebung,
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    List<String> pakete() => Directory(p.join(kopie.path, 'build'))
        .listSync()
        .map((e) => p.basename(e.path))
        .where((name) => name.endsWith('.pkg'))
        .toList();

    test('unbekannte Option: Abbruch mit 64', () async {
      final r = await bauen(<String>['--unsigniert']);
      expect(r.exitCode, 64, reason: '${r.stderr}');
    });

    test(
      'ohne Installer-Identität: Abbruch vor dem Bauen, kein Paket',
      () async {
        _attrappe(u.bin, 'security', 'exit 0'); // kennt keine Identität
        final r = await bauen(const <String>[]);
        expect(r.exitCode, 1, reason: '${r.stderr}');
        expect('${r.stderr}', contains('Abbruch:'));
        expect('${r.stderr}', contains('Developer-ID-Installer-Identität'));
        expect('${r.stderr}', contains('--testbau'));
        expect(u.aufrufe.where((z) => z.startsWith('ditto')), isEmpty);
        expect(pakete(), isEmpty);
      },
    );

    test('signiert, aber nicht mit Developer ID Application (etwa eine '
        'Entwickler-Identität über KASSENECK_SIGN_APP): Abbruch, kein '
        'Paket', () async {
      _attrappe(u.bin, 'security', r'''
case "$*" in
  *codesigning*) echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Muster (ABCDE12345)"' ;;
  *) echo '  1) 76543210FEDCBA9876543210FEDCBA9876543210 "Developer ID Installer: Muster (ABCDE12345)"' ;;
esac''');
      // Die Signatur ist gültig, stammt aber von einer Entwickler-Identität.
      _attrappe(u.bin, 'codesign', r'''
case "$*" in
  -dv*) echo 'Authority=Apple Development: Muster (ABCDE12345)' >&2 ;;
esac
exit 0''');
      final r = await bauen(const <String>[]);
      expect(r.exitCode, 1, reason: '${r.stderr}');
      expect('${r.stderr}', contains('Abbruch:'));
      expect('${r.stderr}', contains('Developer-ID-Application-Signatur'));
      expect(u.aufrufe.where((z) => z.startsWith('pkgbuild')), isEmpty);
      expect(pakete(), isEmpty);
    });

    test('die CI baut ausdrücklich nur einen Testbau', () {
      final ci = _datei(<String>['.github', 'workflows', 'ci.yml']);
      expect(ci, contains('tool/pkg/macos/build_pkg.sh --testbau'));
      expect(
        RegExp(r'build_pkg\.sh\s*$', multiLine: true).hasMatch(ci),
        isFalse,
        reason: 'ein Aufruf ohne --testbau bräche ohne Zertifikat ab',
      );
    });
  });

  test('die Skripte sind gültiges bash (bash -n)', () async {
    for (final skript in <String>[
      'tool/_common.sh',
      'tool/release.sh',
      'tool/build_macos.sh',
      'tool/pkg/macos/build_pkg.sh',
      'tool/notarize_macos.sh',
    ]) {
      final r = await Process.run('bash', <String>['-n', skript]);
      expect(r.exitCode, 0, reason: '$skript: ${r.stderr}');
    }
  });

  test('Ausgaben nennen Variablen vor einem Anführungszeichen in Klammern', () {
    // „$name“ zöge das mehrbytige Zeichen in den Namen (unbound variable).
    for (final skript in <String>[
      'tool/_common.sh',
      'tool/release.sh',
      'tool/build_macos.sh',
      'tool/pkg/macos/build_pkg.sh',
    ]) {
      expect(
        RegExp(
          r'\$[A-Za-z_][A-Za-z0-9_]*[“”„‘’–—…]',
        ).allMatches(_datei(<String>[skript])).map((m) => m.group(0)),
        isEmpty,
        reason: skript,
      );
    }
  });
}
