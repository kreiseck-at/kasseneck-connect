import 'dart:io';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

/// Die vier Dateien, die die Kasse im Download-Abschnitt **fest** verlinkt
/// (`connect/latest/<name>`). Diese Liste ist hier absichtlich noch einmal von
/// Hand hingeschrieben statt aus `downloadLatestNames` abgeleitet: sie ist der
/// Abgleich mit der Kasse. Wer einen Namen ändert, muss ihn hier ändern — und
/// merkt spätestens dabei, dass drüben Links brechen.
const List<String> kasseDownloadLinks = <String>[
  'KasseneckConnect-macos-arm64.pkg',
  'KasseneckConnect-macos-x64.pkg',
  'KasseneckConnect-windows-x64.exe',
  'KasseneckConnect-linux-x64.deb',
];

void main() {
  final releaseScript = File('tool/release.sh').readAsStringSync();
  final common = File('tool/_common.sh').readAsStringSync();
  final readme = File('README.md').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final innoScript = File(
    'tool/installer/windows/KasseneckConnect.iss',
  ).readAsStringSync();

  group('Dateinamen der Auslieferung', () {
    test('genau die vier Namen, die die Kasse verlinkt', () {
      expect(
        downloadLatestNames.values.toSet(),
        kasseDownloadLinks.toSet(),
        reason: 'lib/src/downloads.dart weicht von der Kassen-Liste ab',
      );
    });

    test('die Feed-Schlüssel liegen fest', () {
      expect(downloadLatestNames.keys.toList(), <String>[
        'darwin-arm64',
        'darwin-x64',
        'windows-x64',
        'linux-x64',
      ]);
    });

    test('versionierter Name steckt die Version an die richtige Stelle', () {
      expect(
        versionedDownloadName('darwin-arm64', '0.1.0'),
        'KasseneckConnect-0.1.0-macos-arm64.pkg',
      );
      expect(
        versionedDownloadName('windows-x64', '1.2.3'),
        'KasseneckConnect-1.2.3-windows-x64.exe',
      );
      expect(
        versionedDownloadName('linux-x64', '0.1.0'),
        'KasseneckConnect-0.1.0-linux-x64.deb',
      );
    });

    test('Version herausnehmen führt auf den latest-Namen zurück', () {
      for (final entry in downloadLatestNames.entries) {
        for (final version in <String>['0.1.0', '10.20.30']) {
          final versioned = versionedDownloadName(entry.key, version);
          expect(
            latestDownloadName(versioned, version),
            entry.value,
            reason: '${entry.key} bei Version $version',
          );
        }
      }
    });

    test('eine unbekannte Plattform fliegt auf', () {
      expect(
        () => versionedDownloadName('haiku-m68k', '0.1.0'),
        throwsArgumentError,
      );
    });
  });

  group('Die Skripte bauen genau diese Namen', () {
    test('release.sh nennt alle vier Ziele', () {
      for (final name in kasseDownloadLinks) {
        expect(
          releaseScript,
          contains(name),
          reason: 'tool/release.sh erwähnt $name nicht',
        );
      }
    });

    test('release.sh kennt alle vier Feed-Schlüssel', () {
      for (final key in downloadLatestNames.keys) {
        expect(releaseScript, contains(key), reason: key);
      }
    });

    test('_common.sh trägt denselben Namensrumpf', () {
      expect(common, contains('KasseneckConnect-\$version-\$os-\$arch.\$ext'));
      for (final name in kasseDownloadLinks) {
        expect(common, contains(name), reason: name);
      }
    });

    test('das Inno-Skript baut den Windows-Namen ohne „-setup"', () {
      expect(
        innoScript,
        contains(
          'OutputBaseFilename=KasseneckConnect-{#AppVersion}-windows-x64',
        ),
      );
      expect(innoScript, isNot(contains('-setup')));
    });

    test('die README-Tabelle führt alle vier Dateien', () {
      for (final name in kasseDownloadLinks) {
        expect(readme, contains(name), reason: 'README nennt $name nicht');
      }
    });
  });

  group('Version', () {
    test('agentVersion und pubspec.yaml sagen dasselbe', () {
      final match = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(match, isNotNull, reason: 'pubspec.yaml hat keine version:-Zeile');
      expect(
        agentVersion,
        match!.group(1),
        reason:
            'lib/src/version.dart und pubspec.yaml driften auseinander — '
            'der Update-Feed und GET /v1/status würden lügen',
      );
    });

    test('die Version ist ein SemVer-Dreiklang', () {
      expect(agentVersion, matches(RegExp(r'^\d+\.\d+\.\d+(?:[-+].*)?$')));
    });
  });
}
