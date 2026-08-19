import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ConfigPaths.forPlatform', () {
    test('macOS legt unter Library/Application Support ab', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{'HOME': '/Users/testuser'},
        operatingSystem: 'macos',
      );
      expect(
        paths.directory.path,
        '/Users/testuser/Library/Application Support/KasseneckConnect',
      );
      expect(p.basename(paths.configFile.path), 'config.json');
    });

    // Installiert wird ohne Administratorrechte nach %LocalAppData% — dorthin
    // gehört auch die Konfiguration, sonst schriebe der Agent in ein
    // Verzeichnis, in dem die Kassenkraft gar nichts zu sagen hat.
    test('Windows nutzt LOCALAPPDATA', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{
          'LOCALAPPDATA': r'C:\Users\kasse\AppData\Local',
          'ProgramData': r'C:\ProgramData',
        },
        operatingSystem: 'windows',
      );
      expect(paths.directory.path, contains(r'C:\Users\kasse\AppData\Local'));
      expect(p.basename(paths.directory.path), 'KasseneckConnect');
      expect(paths.directory.path, isNot(contains('ProgramData')));
    });

    test('ohne LOCALAPPDATA bleibt ProgramData der Notnagel', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{'ProgramData': r'C:\ProgramData'},
        operatingSystem: 'windows',
      );
      expect(paths.directory.path, contains('ProgramData'));
      expect(p.basename(paths.directory.path), 'KasseneckConnect');
    });

    test('ohne jede Umgebung bleibt C:\\ProgramData', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{},
        operatingSystem: 'windows',
      );
      expect(paths.directory.path, contains(r'C:\ProgramData'));
    });

    test('Linux nutzt XDG_CONFIG_HOME, sonst ~/.config', () {
      final withXdg = ConfigPaths.forPlatform(
        environment: <String, String>{
          'HOME': '/home/t',
          'XDG_CONFIG_HOME': '/home/t/cfg',
        },
        operatingSystem: 'linux',
      );
      expect(withXdg.directory.path, '/home/t/cfg/kasseneck-connect');

      final withoutXdg = ConfigPaths.forPlatform(
        environment: <String, String>{'HOME': '/home/t'},
        operatingSystem: 'linux',
      );
      expect(withoutXdg.directory.path, '/home/t/.config/kasseneck-connect');
    });

    test('KASSENECK_CONNECT_HOME sticht das Betriebssystem aus', () {
      for (final os in <String>['macos', 'windows', 'linux']) {
        final paths = ConfigPaths.forPlatform(
          environment: <String, String>{
            'HOME': '/Users/testuser',
            'ProgramData': r'C:\ProgramData',
            configHomeEnvVar: '/tmp/connect-home',
          },
          operatingSystem: os,
        );
        expect(paths.directory.path, '/tmp/connect-home', reason: os);
      }
    });

    test('leere Überschreibung wird ignoriert', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{
          'HOME': '/Users/testuser',
          configHomeEnvVar: '  ',
        },
        operatingSystem: 'macos',
      );
      expect(paths.directory.path, contains('Library'));
    });

    test('Log liegt im Unterverzeichnis logs', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{configHomeEnvVar: '/tmp/connect-home'},
        operatingSystem: 'macos',
      );
      expect(paths.logDirectory.path, p.join('/tmp/connect-home', 'logs'));
    });
  });
}
