import 'package:kasseneck_connect/kasseneck_connect.dart';
import 'package:test/test.dart';

void main() {
  test('kurze Kennungen werden zur Basis-UUID', () {
    expect(canonicalUuid('ff02'), '0000ff02-0000-1000-8000-00805f9b34fb');
    expect(canonicalUuid('0000FF03'), '0000ff03-0000-1000-8000-00805f9b34fb');
    expect(
      canonicalUuid('F000FFC0-0451-4000-B000-000000000000'),
      'f000ffc0-0451-4000-b000-000000000000',
    );
    expect(() => canonicalUuid('xyz'), throwsFormatException);
    expect(() => canonicalUuid('fff'), throwsFormatException);
  });

  test('Geräte-Kennung: nur UUID-Form', () {
    expect(isValidDeviceId('0A1B2C3D-0000-4000-8000-0123456789AB'), isTrue);
    expect(isValidDeviceId('0a1b2c3d-0000-4000-8000-0123456789ab'), isTrue);
    expect(isValidDeviceId('AA:BB:CC:DD:EE:FF'), isFalse);
    expect(isValidDeviceId('../etc'), isFalse);
  });

  test(
    'Sperrliste: Tastatur, FIDO, Firmware-Update gesperrt, Druckerdienst frei',
    () {
      expect(isBlockedService('1812'), isTrue);
      expect(isBlockedService('fffd'), isTrue);
      expect(isBlockedService('FFF9'), isTrue);
      expect(isBlockedService('fe59'), isTrue);
      expect(isBlockedService('0000fe59-0000-1000-8000-00805f9b34fb'), isTrue);
      expect(isBlockedService('00001530-1212-efde-1523-785feabcd123'), isTrue);
      expect(isBlockedService('ff00'), isFalse);
      expect(isBlockedService('kein uuid'), isFalse);
    },
  );

  test('Sperrliste Merkmale: Seriennummer gesperrt, Schreibmerkmal frei', () {
    expect(isBlockedCharacteristic('2a25'), isTrue);
    expect(
      isBlockedCharacteristic('00002a03-0000-1000-8000-00805f9b34fb'),
      isTrue,
    );
    expect(isBlockedCharacteristic('ff02'), isFalse);
    expect(isBlockedCharacteristic('2a02'), isFalse);
    expect(isBlockedCharacteristic('???'), isFalse);
  });
}
