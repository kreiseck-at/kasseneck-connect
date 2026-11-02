import 'package:kasseneck_connect/src/update/system_info.dart';
import 'package:test/test.dart';

import 'support/fake_process_runner.dart';

void main() {
  group('readSystemInfo', () {
    test('macOS: Systemversion aus sw_vers, Prozessor aus uname', () async {
      final runner = FakeProcessRunner()
        ..stdoutOf['-productVersion'] = '26.5.1\n'
        ..stdoutOf['-m'] = 'arm64\n';
      final info = await readSystemInfo(
        run: runner.runner,
        operatingSystem: 'macos',
      );
      expect(info.os, 'macos');
      expect(info.osVersion, '26.5.1');
      expect(info.arch, 'arm64');
      expect(runner.sawCall('sw_vers', <String>['-productVersion']), isTrue);
      expect(runner.sawCall('uname', <String>['-m']), isTrue);
    });

    test('scheitern die Programme, bleiben die Angaben leer', () async {
      final runner = FakeProcessRunner(defaultExitCode: 1);
      final info = await readSystemInfo(
        run: runner.runner,
        operatingSystem: 'macos',
      );
      expect(info.os, 'macos');
      expect(info.osVersion, isNull);
      expect(info.arch, isNull);
    });

    test('fehlt ein Programm ganz, wirft es nicht', () async {
      final runner = FakeProcessRunner()
        ..missing.addAll(<String>['sw_vers', 'uname']);
      final info = await readSystemInfo(
        run: runner.runner,
        operatingSystem: 'macos',
      );
      expect(info.osVersion, isNull);
      expect(info.arch, isNull);
    });

    test('leere oder überlange Ausgabe zählt nicht', () async {
      final runner = FakeProcessRunner()
        ..stdoutOf['-productVersion'] = '   \n'
        ..stdoutOf['-m'] = 'x' * 40;
      final info = await readSystemInfo(
        run: runner.runner,
        operatingSystem: 'macos',
      );
      expect(info.osVersion, isNull);
      expect(info.arch, isNull);
    });

    test('toJson nennt nur die drei Angaben', () {
      const info = SystemInfo(os: 'macos', osVersion: '26.5.1', arch: 'arm64');
      expect(info.toJson(), <String, Object?>{
        'os': 'macos',
        'osVersion': '26.5.1',
        'arch': 'arm64',
      });
    });
  });
}
