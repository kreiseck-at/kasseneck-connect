import 'dart:io';
import 'dart:math';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ConfigStore store;
  late AgentLog log;
  late DateTime now;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('connect-pair-');
    store = ConfigStore.forDirectory(temp);
    log = AgentLog(Directory(p.join(temp.path, 'logs')));
    now = DateTime(2026, 8, 19, 10);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Pairing makePairing() =>
      Pairing(store: store, log: log, clock: () => now, random: Random(7));

  test(
    'newCode liefert sechs Ziffern und merkt sie in der Konfiguration',
    () async {
      final pairing = makePairing();
      final code = await pairing.newCode();

      expect(code, matches(RegExp(r'^\d{6}$')));
      final config = await store.load();
      expect(config.pairing.code, code);
      expect(config.pairing.expiresAt, now.add(pairingCodeLifetime));
      expect(config.pairing.failedAttempts, 0);
    },
  );

  test('richtiger Code wird angenommen und ist danach verbraucht', () async {
    final pairing = makePairing();
    final code = await pairing.newCode();

    expect(await pairing.verify(code), isNull);
    expect((await store.load()).pairing.code, isNull);
    expect(await pairing.verify(code), PairFailure.invalid);
  });

  test(
    'falscher Code zählt Fehlversuche, fünf sperren für 60 Sekunden',
    () async {
      final pairing = makePairing();
      final code = await pairing.newCode();

      for (var i = 0; i < 5; i++) {
        expect(
          await pairing.verify('000000'),
          PairFailure.invalid,
          reason: '$i',
        );
      }
      expect(
        (await store.load()).pairing.lockedUntil,
        now.add(pairingLockDuration),
      );

      // Gesperrt: auch der richtige Code prallt ab.
      expect(await pairing.verify(code), PairFailure.locked);

      now = now.add(const Duration(seconds: 61));
      expect(await pairing.verify(code), isNull);
    },
  );

  test('abgelaufener Code meldet pair_expired', () async {
    final pairing = makePairing();
    final code = await pairing.newCode();

    now = now.add(pairingCodeLifetime + const Duration(seconds: 1));
    expect(await pairing.verify(code), PairFailure.expired);
    expect((await store.load()).pairing.code, isNull);
  });

  test('ohne offenen Vorgang ist jeder Code ungültig', () async {
    final pairing = makePairing();
    expect(await pairing.verify('123456'), PairFailure.invalid);
  });

  test('issueToken legt nur den SHA-256-Hash ab', () async {
    final pairing = makePairing();
    final token = await pairing.issueToken();

    expect(token.length, greaterThanOrEqualTo(43));
    expect(token, isNot(contains('=')));
    final config = await store.load();
    expect(config.tokenHashes, <String>[hashToken(token)]);
    expect(config.tokenHashes.single, isNot(contains(token)));
  });

  test(
    'zwei Tokens können nebeneinander bestehen, revoke entfernt eines',
    () async {
      final pairing = makePairing();
      final first = await pairing.issueToken();
      final second = await pairing.issueToken();

      expect(first, isNot(second));
      expect((await store.load()).tokenHashes, hasLength(2));

      expect(await pairing.revokeToken(first), isTrue);
      expect((await store.load()).tokenHashes, <String>[hashToken(second)]);
      expect(await pairing.revokeToken(first), isFalse);
    },
  );

  test(
    'ein zweiter Prozess sieht den Code aus der Konfigurationsdatei',
    () async {
      final code = await makePairing().newCode();
      // Frische Instanz auf demselben Verzeichnis — wie CLI `pair` neben `run`.
      expect(await makePairing().verify(code), isNull);
    },
  );

  group('openPairingPage', () {
    late List<List<String>> calls;
    late Pairing pairing;

    setUp(() {
      calls = <List<String>>[];
      pairing = Pairing(
        store: store,
        log: log,
        clock: () => now,
        random: Random(7),
        runProcess: (executable, arguments) async {
          calls.add(<String>[executable, ...arguments]);
          return ProcessResult(0, 0, '', '');
        },
      );
    });

    Future<void> open(String os) => pairing.openPairingPage(
      '123456',
      27182,
      operatingSystem: os,
      environment: const <String, String>{},
    );

    test('macOS öffnet mit open', () async {
      await open('macos');
      expect(calls.single, <String>[
        'open',
        'https://kasse.kasseneck.at/connect#code=123456&port=27182',
      ]);
    });

    test('Linux öffnet mit xdg-open', () async {
      await open('linux');
      expect(calls.single.first, 'xdg-open');
      expect(calls.single.last, contains('&port=27182'));
    });

    test('Windows nimmt rundll32, nicht cmd start', () async {
      await open('windows');
      expect(calls.single, <String>[
        'rundll32',
        'url.dll,FileProtocolHandler',
        'https://kasse.kasseneck.at/connect#code=123456&port=27182',
      ]);
      // `cmd /c start` zerlegte die Adresse am `&` — genau das darf nicht sein.
      expect(calls.single.first, isNot('cmd'));
      expect(calls.single.last, endsWith('&port=27182'));
    });

    test('KASSENECK_CONNECT_NO_BROWSER=1 unterdrückt das Öffnen', () async {
      await pairing.openPairingPage(
        '123456',
        27182,
        operatingSystem: 'macos',
        environment: const <String, String>{noBrowserEnvVar: '1'},
      );
      expect(calls, isEmpty);
    });

    test('scheitert das Programm, bleibt es bei einer Warnung', () async {
      final failing = Pairing(
        store: store,
        log: log,
        runProcess: (executable, arguments) async =>
            throw ProcessException(executable, arguments, 'nicht gefunden'),
      );
      await failing.openPairingPage(
        '123456',
        27182,
        operatingSystem: 'linux',
        environment: const <String, String>{},
      );
      expect(log.file.readAsStringSync(), contains('Browser'));
    });
  });
}
