import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/druck_aufbau.dart';
import 'support/fake_printer.dart';

/// Druck und Statustakt warten nie auf die `config.json`: hält ein anderer
/// Prozess die Sperre (Kommandozeile, zweiter Start), geht der Bon trotzdem
/// sofort hinaus; was zu merken ist, schreibt Connect danach im Hintergrund.
void main() {
  test(
    'gesperrte config.json: der Bon geht, statusCapableAt folgt später',
    () async {
      final drucker = await FakeTcpPrinter.start(
        dleEot: const <int, int>{2: 0x12, 4: 0x12},
      );
      final a = DruckAufbau.erstellen();
      addTearDown(() async {
        await a.aufraeumen();
        await drucker.stop();
      });
      final id = await a.drucker(drucker.port);

      final worker = p.join('test', 'support', 'sperre_worker.dart');
      final halter = await Process.start(Platform.resolvedExecutable, <String>[
        'run',
        worker,
        a.temp.path,
      ]);
      final bereit = Completer<void>();
      final abo = halter.stdout.transform(utf8.decoder).listen((t) {
        if (t.contains('bereit') && !bereit.isCompleted) bereit.complete();
      });
      halter.stderr.drain<void>().ignore();
      // Läuft vor dem Aufräumen oben: hinge der Druck doch an der Sperre,
      // gäbe sie so frei, und der Test endete rot statt nie.
      addTearDown(() => halter.kill());
      await bereit.future.timeout(const Duration(seconds: 60));

      // Der Druck kehrt zurück, obwohl die Sperre steht – sonst liefe der
      // Test in seine Zeitgrenze.
      final ergebnis = await a.drucke(id);
      expect(ergebnis.ok, isTrue);
      await drucker.warteAufDruck(0);
      expect(drucker.druckVerbindungen.single, beispielBon);

      await halter.stdin.close();
      await halter.exitCode;
      await abo.cancel();
      await a.registry.hintergrundErledigt();
      expect((await a.store.load()).printers.single.statusCapableAt, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('ein Fehler im Hintergrund landet im Log, nie beim Aufrufer', () async {
    final a = DruckAufbau.erstellen();
    addTearDown(a.aufraeumen);
    a.registry.imHintergrund('Probe', () async => throw StateError('kaputt'));
    await a.registry.hintergrundErledigt();
    expect(
      a.logZeilen.where((z) => z.contains('Probe: Bad state: kaputt')),
      hasLength(1),
    );
  });
}
