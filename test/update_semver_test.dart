import 'package:kasseneck_connect/src/update/semver.dart';
import 'package:test/test.dart';

void main() {
  group('compareVersions', () {
    test('höhere Teilnummer gewinnt, auch zweistellig', () {
      expect(compareVersions('1.4.0', '1.3.9'), greaterThan(0));
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.3.9', '1.4.0'), lessThan(0));
    });

    test('gleiche Versionen sind gleich', () {
      expect(compareVersions('1.4.0', '1.4.0'), 0);
    });

    test('alles außer MAJOR.MINOR.PATCH ist ein FormatException', () {
      for (final falsch in <String>[
        '1.4',
        'v1.4.0',
        '',
        '1.4.0-beta',
        '1.4.x',
        ' 1.4.0',
      ]) {
        expect(
          () => compareVersions(falsch, '1.0.0'),
          throwsFormatException,
          reason: falsch,
        );
      }
    });
  });

  group('isNewer', () {
    test('nur echt neuere Versionen zählen', () {
      expect(isNewer('1.4.1', '1.4.0'), isTrue);
      expect(isNewer('1.4.0', '1.4.0'), isFalse);
      expect(isNewer('1.3.0', '1.4.0'), isFalse);
    });
  });
}
