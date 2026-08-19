import 'dart:convert';

import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

void main() {
  group('AgentConfig', () {
    test('Standardwerte', () {
      final config = AgentConfig();
      expect(config.schemaVersion, currentSchemaVersion);
      expect(config.port, 27182);
      expect(config.tokenHashes, isEmpty);
      expect(config.printers, isEmpty);
      expect(config.terminal, isNull);
      expect(config.updateChannel, 'stable');
    });

    test('JSON-Roundtrip erhält alle Felder', () {
      final original = AgentConfig(
        port: 27183,
        tokenHashes: <String>['aa11', 'bb22'],
        printers: <PrinterConfig>[
          PrinterConfig(
            id: 'p1',
            name: 'Bon',
            kind: PrinterKind.tcp9100,
            host: '192.168.0.20',
          ),
          PrinterConfig(
            id: 'p2',
            name: 'ePOS',
            kind: PrinterKind.epos,
            host: 'drucker.local',
            port: 443,
            devid: 'local_printer',
          ),
        ],
        terminal: TerminalConfig(host: '192.168.0.30', port: 8080, tid: 'T1'),
        updateChannel: 'stable',
      );

      final decoded = jsonDecode(jsonEncode(original.toJson())) as Object?;
      final copy = AgentConfig.fromJson(readMap(decoded)!);

      expect(copy.port, 27183);
      expect(copy.tokenHashes, <String>['aa11', 'bb22']);
      expect(copy.printers, hasLength(2));
      expect(copy.printers[0].kind, PrinterKind.tcp9100);
      expect(copy.printers[0].port, 9100, reason: 'Standardport der Anbindung');
      expect(copy.printers[1].kind, PrinterKind.epos);
      expect(copy.printers[1].port, 443);
      expect(copy.printers[1].devid, 'local_printer');
      expect(copy.terminal?.host, '192.168.0.30');
      expect(copy.terminal?.tid, 'T1');
    });

    test('fromJson ist tolerant gegen fehlende und falsche Felder', () {
      final config = AgentConfig.fromJson(<String, Object?>{
        'port': '27185',
        'tokenHashes': <Object?>['ok', 42, null],
        'printers': <Object?>[
          <String, Object?>{
            'id': 'p1',
            'kind': 'unbekannt',
            'host': '10.0.0.5',
          },
          'kaputt',
        ],
        'terminal': 'kaputt',
      });

      expect(config.schemaVersion, currentSchemaVersion);
      expect(config.port, 27185, reason: 'numerischer String wird gelesen');
      expect(config.tokenHashes, <String>['ok']);
      expect(config.printers, hasLength(1));
      expect(config.printers.single.kind, PrinterKind.tcp9100);
      expect(config.printers.single.name, '');
      expect(config.terminal, isNull);
      expect(config.updateChannel, 'stable');
    });

    test('leeres JSON ergibt die Standardkonfiguration', () {
      final config = AgentConfig.fromJson(<String, Object?>{});
      expect(config.port, 27182);
      expect(config.printers, isEmpty);
    });

    test('copyWith kann das Terminal löschen', () {
      final config = AgentConfig(terminal: TerminalConfig(host: '10.0.0.1'));
      expect(config.copyWith(port: 27184).terminal, isNotNull);
      expect(config.copyWith(clearTerminal: true).terminal, isNull);
      expect(config.copyWith(port: 27184).port, 27184);
    });

    test('Listen sind unveränderlich', () {
      final config = AgentConfig(tokenHashes: <String>['a']);
      expect(() => config.tokenHashes.add('b'), throwsUnsupportedError);
      expect(() => config.printers.clear(), throwsUnsupportedError);
    });
  });

  group('Port aus der Datei', () {
    test('0 wird auf den Standardport normalisiert', () {
      expect(
        AgentConfig.fromJson(<String, Object?>{'port': 0}).port,
        defaultAgentPort,
      );
    });

    test('Unsinn wird auf den Standardport normalisiert', () {
      for (final value in <Object?>[-1, 70000, 'abc', null]) {
        expect(
          AgentConfig.fromJson(<String, Object?>{'port': value}).port,
          defaultAgentPort,
          reason: '$value',
        );
      }
    });

    test('ein echter Port bleibt stehen', () {
      expect(
        AgentConfig.fromJson(<String, Object?>{'port': 27185}).port,
        27185,
      );
    });

    test('programmatisch bleibt 0 erlaubt (freier Port im Test)', () {
      expect(AgentConfig(port: 0).port, 0);
    });
  });

  group('allowDevOrigins', () {
    test('ist standardmäßig aus und überlebt den Roundtrip', () {
      expect(AgentConfig().allowDevOrigins, isFalse);
      final config = AgentConfig(allowDevOrigins: true);
      expect(AgentConfig.fromJson(config.toJson()).allowDevOrigins, isTrue);
    });

    test('nur echtes true schaltet frei', () {
      for (final value in <Object?>['true', 1, null]) {
        expect(
          AgentConfig.fromJson(<String, Object?>{
            'allowDevOrigins': value,
          }).allowDevOrigins,
          isFalse,
          reason: '$value',
        );
      }
    });
  });
}
