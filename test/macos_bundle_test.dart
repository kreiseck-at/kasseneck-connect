@TestOn('!windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Das App-Paket `Kasseneck Connect.app` und die Skripte, die es bauen,
/// verpacken und entfernen. Gebaut wird im Test nichts (das braucht Swift,
/// Zertifikate und einige Minuten); geprüft werden Vorlage, Symbol und der
/// Text der Skripte.
String _pfad(List<String> teile) =>
    p.joinAll(<String>[Directory.current.path, ...teile]);

final File _vorlage = File(_pfad(<String>['tool', 'macos', 'Info.plist.in']));
final File _symbol = File(_pfad(<String>['tool', 'macos', 'AppIcon.icns']));
final File _common = File(_pfad(<String>['tool', '_common.sh']));
final File _build = File(_pfad(<String>['tool', 'build_macos.sh']));
final File _pkg = File(_pfad(<String>['tool', 'pkg', 'macos', 'build_pkg.sh']));
final File _uninstall = File(
  _pfad(<String>['tool', 'pkg', 'macos', 'uninstall.sh']),
);
final File _ci = File(_pfad(<String>['.github', 'workflows', 'ci.yml']));

const String _paket = 'Kasseneck Connect.app';
const String _imPaket =
    '/usr/local/kasseneck-connect/Kasseneck Connect.app/Contents/MacOS/kasseneck-connect';
const String _bluetoothText =
    'Kasseneck Connect verbindet die Kasse mit Bluetooth-Druckern wie dem '
    'Etikettendrucker.';

void main() {
  group('Info.plist', () {
    test('Info.plist.in enthält Bluetooth-Text und @VERSION@', () {
      final text = _vorlage.readAsStringSync();
      expect(_eintraege(text), <String, String>{
        'CFBundleIdentifier': 'at.kasseneck.connect',
        'CFBundleName': 'Kasseneck Connect',
        'CFBundleDisplayName': 'Kasseneck Connect',
        'CFBundleExecutable': 'kasseneck-connect',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '@VERSION@',
        'CFBundleVersion': '@VERSION@',
        'CFBundleIconFile': 'AppIcon',
        'CFBundleInfoDictionaryVersion': '6.0',
        'LSMinimumSystemVersion': '14.0',
        'LSUIElement': 'true',
        'NSBluetoothAlwaysUsageDescription': _bluetoothText,
      });
    });

    test('mit eingesetzter Version eine gültige Plist (plutil)', () async {
      final temp = Directory.systemTemp.createTempSync('connect-plist-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final plist = File(p.join(temp.path, 'Info.plist'))
        ..writeAsStringSync(
          _vorlage.readAsStringSync().replaceAll('@VERSION@', '9.8.7'),
        );

      final lint = await Process.run('plutil', <String>['-lint', plist.path]);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
      for (final (schluessel, wert) in <(String, String)>[
        ('NSBluetoothAlwaysUsageDescription', _bluetoothText),
        ('CFBundleVersion', '9.8.7'),
        ('LSUIElement', 'true'),
      ]) {
        final r = await Process.run('plutil', <String>[
          '-extract',
          schluessel,
          'raw',
          plist.path,
        ]);
        expect('${r.stdout}'.trim(), wert, reason: schluessel);
      }
    }, testOn: 'mac-os');

    test('das Symbol liegt als icns bei, bis 1024 px', () {
      final bytes = _symbol.readAsBytesSync();
      final daten = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'icns');
      expect(daten.getUint32(4), bytes.length);

      final typen = <String>{};
      var stelle = 8;
      while (stelle + 8 <= bytes.length) {
        typen.add(String.fromCharCodes(bytes.sublist(stelle, stelle + 4)));
        final laenge = daten.getUint32(stelle + 4);
        expect(laenge, greaterThanOrEqualTo(8));
        stelle += laenge;
      }
      expect(stelle, bytes.length);
      // ic07 = 128 px, ic10 = 512@2x (1024 px).
      expect(typen, containsAll(<String>['ic07', 'ic10']));
    });
  });

  group('Skripte', () {
    test('sind gültiges bash (bash -n)', () async {
      for (final skript in <File>[_common, _build, _pkg, _uninstall]) {
        final r = await Process.run('bash', <String>['-n', skript.path]);
        expect(r.exitCode, 0, reason: '${skript.path}: ${r.stderr}');
      }
    });

    test('der Paketpfad steht überall in Anführungszeichen', () {
      for (final datei in <File>[_common, _build, _pkg, _uninstall, _ci]) {
        expect(
          _ungeschuetzt(datei.readAsStringSync()),
          isEmpty,
          reason: datei.path,
        );
      }
    });

    test('die Prüfung auf Anführungszeichen schlägt an', () {
      expect(
        _ungeschuetzt(
          'APP="build/$_paket"\n'
          'cp \$APP /tmp\n'
          'ls build/$_paket\n'
          'ls "build/$_paket"\n'
          'HELFER="\$APP/Contents/MacOS/kasseneck-bluetooth"\n'
          'codesign --sign x \${HELFER}\n'
          'echo "\$(basename "\$HELFER")"\n',
        ),
        <String>[
          r'Zeile 2: cp $APP /tmp',
          'Zeile 3: ls build/$_paket',
          r'Zeile 6: codesign --sign x ${HELFER}',
        ],
      );
    });

    test('erst das Hilfsprogramm, dann das Paket signieren', () {
      final text = _common.readAsStringSync();
      final start = text.indexOf('sign_app_bundle() {');
      expect(start, greaterThanOrEqualTo(0));
      final funktion = text.substring(start, text.indexOf('\n}\n', start));
      final aufrufe = RegExp(
        // Ein Aufruf samt Fortsetzungszeilen (Backslash am Zeilenende).
        r'codesign --force(?:[^\n\\]|\\\n)*',
      ).allMatches(funktion).map((m) => m.group(0)!).toList();

      expect(aufrufe, hasLength(2));
      // Das Hilfsprogramm ohne Berechtigungen, mit Hardened Runtime.
      expect(aufrufe[0], contains('--options runtime --timestamp'));
      expect(aufrufe[0], contains(r'/Contents/MacOS/kasseneck-bluetooth"'));
      expect(aufrufe[0], isNot(contains('--entitlements')));
      // Das Paket mit der Berechtigung, ohne die die Dart-Binary nicht startet.
      expect(aufrufe[1], contains('--options runtime --timestamp'));
      expect(
        aufrufe[1],
        contains('--entitlements tool/entitlements-macos.plist'),
      );
      expect(funktion, contains('codesign --verify --strict --deep'));
    });

    test(
      'build_macos.sh setzt das Paket zusammen und macht die Startprobe',
      () {
        final text = _build.readAsStringSync();
        expect(text, contains('tool/macos/Info.plist.in'));
        expect(text, contains('@VERSION@'));
        expect(text, contains('tool/macos/AppIcon.icns'));
        expect(text, contains('--product kasseneck-bluetooth'));
        expect(text, contains('sign_app_bundle "\$APP"'));
        expect(
          text,
          contains(r'"$APP/Contents/MacOS/kasseneck-connect" version'),
        );
      },
    );

    test('das .pkg legt das Paket ab und verschiebt es nie', () {
      final text = _pkg.readAsStringSync();
      expect(text, contains(r'"$STAGE$INSTALL_DIR/$APP_BUNDLE_NAME"'));
      expect(
        text,
        contains(
          r'ln -s "$APP_BUNDLE_NAME/Contents/MacOS/kasseneck-connect" '
          r'"$STAGE$INSTALL_DIR/kasseneck-connect"',
        ),
      );
      // Ohne das sucht der Installer nach einem Paket mit derselben
      // Kennung (etwa in einem Bauordner) und installiert dorthin.
      expect(text, contains('BundleIsRelocatable'));
      expect(text, contains(r'--component-plist "$COMPONENTS"'));
      // Schon signiert: keine zweite Signatur.
      expect(text, contains(r'signed_with_developer_id "$STAGED_APP"'));
    });

    test('postinstall und uninstall.sh nehmen die Binary im Paket', () {
      final pkg = _pkg.readAsStringSync();
      final postinstall = pkg.substring(
        pkg.indexOf("<<'POSTINSTALL'"),
        pkg.lastIndexOf('POSTINSTALL'),
      );
      expect(postinstall, contains('BINARY="$_imPaket"'));
      expect(
        postinstall,
        contains(r'/bin/ln -sfh "$BINARY" /usr/local/bin/kasseneck-connect'),
      );
      expect(postinstall, contains(r'"$BINARY" install-autostart'));

      final uninstall = _uninstall.readAsStringSync();
      expect(uninstall, contains('INSTALL_DIR="/usr/local/kasseneck-connect"'));
      expect(
        uninstall,
        contains(
          r'BINARY="$INSTALL_DIR/Kasseneck Connect.app/Contents/MacOS/'
          'kasseneck-connect"',
        ),
      );
      expect(uninstall, contains(r'/bin/rm -rf "$INSTALL_DIR"'));
    });

    test('die CI testet das Hilfsprogramm und prüft das Paket', () {
      final text = _ci.readAsStringSync();
      expect(
        text,
        contains('swift test --package-path native/macos/KasseneckBluetooth'),
      );
      expect(
        text,
        contains('"build/$_paket"/Contents/MacOS/kasseneck-connect version'),
      );
      expect(
        text,
        contains('plutil -lint "build/$_paket"/Contents/Info.plist'),
      );
    });
  });
}

/// Schlüssel und Werte einer flachen XML-Plist (`string`, `true`, `false`).
Map<String, String> _eintraege(String plist) => <String, String>{
  for (final m in RegExp(
    r'<key>([^<]+)</key>\s*(?:<string>([^<]*)</string>|<(true|false)/>)',
  ).allMatches(plist))
    m.group(1)!: m.group(2) ?? m.group(3)!,
};

/// Zeilen, in denen der Paketpfad oder eine Variable, die ihn trägt, ohne
/// Anführungszeichen steht – das Leerzeichen im Ordnernamen zerlegte sie
/// sonst in zwei Wörter.
///
/// Variablen mit dem Pfad findet die Prüfung selbst: wer ihn zugewiesen
/// bekommt oder aus einer solchen Variable gebaut wird. Dazu kommen
/// `APP_BUNDLE_NAME` aus `_common.sh` und `bundle`, der Parameter von
/// `sign_app_bundle`.
List<String> _ungeschuetzt(String text) {
  final zeilen = text.split('\n');
  final namen = <String>{'APP_BUNDLE_NAME', 'bundle'};
  final zuweisung = RegExp(r'^\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$');
  var gewachsen = true;
  while (gewachsen) {
    gewachsen = false;
    for (final zeile in zeilen) {
      final m = zuweisung.firstMatch(zeile);
      if (m == null || namen.contains(m.group(1))) continue;
      final rechts = m.group(2)!;
      final traegt =
          rechts.contains(_paket) ||
          namen.any((n) => RegExp('\\\$\\{?$n\\b').hasMatch(rechts));
      if (traegt) gewachsen = namen.add(m.group(1)!);
    }
  }

  final variable = RegExp(
    '\\\$\\{?(?:${namen.map(RegExp.escape).join('|')})\\b',
  );
  final funde = <String>[];
  for (final (nummer, zeile) in zeilen.indexed) {
    if (zeile.trimLeft().startsWith('#')) continue;
    final stellen = <int>[
      for (final m in RegExp(RegExp.escape(_paket)).allMatches(zeile)) m.start,
      for (final m in variable.allMatches(zeile)) m.start,
    ];
    for (final stelle in stellen) {
      // In `$(…)` beginnen die Anführungszeichen von vorn.
      var davor = zeile.substring(0, stelle);
      final klammer = davor.lastIndexOf(r'$(');
      if (klammer >= 0) davor = davor.substring(klammer);
      final doppelt = '"'.allMatches(davor.replaceAll(r'\"', '')).length;
      final einfach = "'".allMatches(davor).length;
      if (doppelt.isEven && einfach.isEven) {
        funde.add('Zeile ${nummer + 1}: ${zeile.trim()}');
        break;
      }
    }
  }
  return funde;
}
