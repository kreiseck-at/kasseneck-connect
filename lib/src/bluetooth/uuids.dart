/// Kennungen für Bluetooth: UUID-Normalisierung und CoreBluetooth-Geräte-IDs.
library;

/// Basis-UUID des Bluetooth-SIG, in die 16-/32-Bit-Kurzformen eingebettet sind.
const String _basisSuffix = '-0000-1000-8000-00805f9b34fb';

final RegExp _hex = RegExp(r'^[0-9a-f]+$');
final RegExp _uuid128 = RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
final RegExp _deviceId = RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

/// Bringt eine 16-, 32- oder 128-Bit-UUID in die 128-Bit-Kleinschreibung.
///
/// Wirft [FormatException], wenn die Eingabe keine dieser Formen hat.
String canonicalUuid(String uuid) {
  final s = uuid.trim().toLowerCase();
  if (s.length == 4 && _hex.hasMatch(s)) {
    return '0000$s$_basisSuffix';
  }
  if (s.length == 8 && _hex.hasMatch(s)) {
    return '$s$_basisSuffix';
  }
  if (_uuid128.hasMatch(s)) {
    return s;
  }
  throw FormatException('Keine gültige Bluetooth-UUID', uuid);
}

/// Prüft eine CoreBluetooth-Geräte-Kennung (UUID-Schreibweise, 8-4-4-4-12).
bool isValidDeviceId(String id) => _deviceId.hasMatch(id.toLowerCase());
