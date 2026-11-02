/// Sperrliste für GATT-Dienste und -Merkmale.
///
/// Quelle: Web-Bluetooth-Registry (github.com/WebBluetoothCG/registries,
/// Datei gatt_blocklist.txt), abgerufen am 2026-10-29. Übernommen sind nur
/// die vollständig ausgeschlossenen Einträge (ohne `exclude-reads` und
/// `exclude-writes`), dazu der Nordic Secure DFU Dienst (fe59), der in der
/// Registry fehlt, aber Firmware ohne Signaturprüfung einspielen kann.
library;

import 'uuids.dart';

/// Gesperrte Dienste (kanonische 128-Bit-Form).
final Set<String> _dienste = <String>{
  // Tastaturen und andere HID-Geräte: Seiten würden zu Keyloggern.
  '1812',
  // Firmware-Update ohne Signaturprüfung: Nordic Legacy DFU, TI OAD,
  // Cypress Bootloader.
  '00001530-1212-efde-1523-785feabcd123',
  'f000ffc0-0451-4000-b000-000000000000',
  '00060000-0000-1000-8000-00805f9b34fb',
  // Nordic Secure DFU.
  'fe59',
  // FIDO: systemweite Kopplung erlaubt es Seiten, andere Seiten zu mimen.
  'fffd',
  'fff9',
  'fde2',
}.map(canonicalUuid).toSet();

/// Gesperrte Merkmale (kanonische 128-Bit-Form).
final Set<String> _merkmale = <String>{
  // Reconnection Address: Verbindungsparameter bleiben unangetastet.
  '2a03',
  // Serial Number String: standardisierte Kennung, Datenschutz.
  '2a25',
}.map(canonicalUuid).toSet();

bool _gesperrt(Set<String> liste, String uuid) {
  try {
    return liste.contains(canonicalUuid(uuid));
  } on FormatException {
    // Ungültige Kennungen prüft der Aufrufer selbst.
    return false;
  }
}

/// Ob der GATT-Dienst gesperrt ist (16-/32-/128-Bit-Form).
bool isBlockedService(String uuid) => _gesperrt(_dienste, uuid);

/// Ob das GATT-Merkmal gesperrt ist (16-/32-/128-Bit-Form).
bool isBlockedCharacteristic(String uuid) => _gesperrt(_merkmale, uuid);
