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

    test('Windows nutzt ProgramData', () {
      final paths = ConfigPaths.forPlatform(
        environment: <String, String>{'ProgramData': r'C:\ProgramData'},
        operatingSystem: 'windows',
      );
      expect(paths.directory.path, contains('KasseneckConnect'));
      expect(paths.directory.path, contains('ProgramData'));
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
