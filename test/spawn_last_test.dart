import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Last: Kindprozesse am laufenden Band', () async {
    final ende = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(ende)) {
      await Process.run('true', const <String>[]);
    }
  });
}
