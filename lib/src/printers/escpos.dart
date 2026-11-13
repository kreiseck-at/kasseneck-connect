/// ESC/POS-Abfragen an Bondrucker – Befehlsbytes und das Lesen der Antworten.
///
/// Reine Logik ohne Sockets. Quelle aller Bytes und Bitbelegungen: Epson
/// „ESC/POS Command Reference for TM Printers“, Abschnitte „DLE EOT n
/// (Transmit real-time status)“ und „GS I n (Transmit printer ID)“. Die
/// Belegung bestätigt der Gerätetest an TM-T20III und TM-m30III.
library;

/// `DLE EOT n`: Echtzeitstatus. Der Drucker beantwortet ihn sofort, auch mit
/// vollem Empfangspuffer und im Fehlerzustand, mit genau einem Byte.
List<int> dleEot(int n) => <int>[0x10, 0x04, n];

/// `DLE EOT 1`: Druckerstatus.
const int dleEotDrucker = 1;

/// `DLE EOT 2`: Grund für „offline“ (Deckel, Stopp wegen Papierende).
const int dleEotOfflineGrund = 2;

/// `DLE EOT 4`: Rollenpapiersensor (fast leer, leer).
const int dleEotRollensensor = 4;

/// Maske der festen Bits einer `DLE EOT`-Antwort: Bit 0, 1, 4 und 7.
const int _festeBitsMaske = 0x93;

/// Wert der festen Bits: Bit 0 = 0, Bit 1 = 1, Bit 4 = 1, Bit 7 = 0.
const int _festeBitsWert = 0x12;

/// Ob [byte] eine Antwort auf `DLE EOT` sein kann.
///
/// Jede Antwort auf `DLE EOT 1…4` trägt dieselben festen Bits. Ein Byte ohne
/// dieses Muster ist keine Statusantwort (etwa ein Block der automatischen
/// Statusmeldung ASB, deren erstes Byte Bit 1 = 0 hat) und wird nie gedeutet.
bool istEchtzeitStatus(int byte) =>
    byte >= 0 && byte <= 0xFF && (byte & _festeBitsMaske) == _festeBitsWert;

/// `GS I n`: Kennung des Druckers.
List<int> gsI(int n) => <int>[0x1D, 0x49, n];

/// `GS I 67`: Modellname (`TM-m30III`).
const int gsIModell = 67;

/// `GS I 68`: Seriennummer.
const int gsISeriennummer = 68;

/// Kopf eines `GS I`-Antwortrahmens (`_`).
const int gsIKopf = 0x5F;

/// Ende eines `GS I`-Antwortrahmens (NUL).
const int gsIEnde = 0x00;

/// Längster Inhalt eines `GS I`-Rahmens, der als Antwort gilt. Epson nennt
/// Modell und Seriennummer mit höchstens 16 bzw. 10 Zeichen; was länger ist,
/// ist keine Kennung, sondern Rauschen.
const int gsIMaxLaenge = 40;

/// Stand beim Lesen eines `GS I`-Rahmens.
sealed class GsIStand {
  const GsIStand();
}

/// Es fehlen noch Bytes.
final class GsIUnvollstaendig extends GsIStand {
  const GsIUnvollstaendig();
}

/// Die Bytes sind kein gültiger Rahmen – die Kennung bleibt unbekannt.
final class GsIUngueltig extends GsIStand {
  const GsIUngueltig(this.grund);

  final String grund;
}

/// Ein gültiger Rahmen mit [text].
final class GsIGueltig extends GsIStand {
  const GsIGueltig(this.text);

  final String text;
}

/// Liest einen `GS I`-Rahmen aus [bytes]: `0x5F`, druckbares ASCII (höchstens
/// [gsIMaxLaenge] Zeichen, nicht leer), `0x00`.
///
/// Bytes vor dem Kopf werden übersprungen: weder eine `DLE EOT`-Antwort
/// (Bit 0 = 0) noch ein ASB-Block (Bit 4 = 0 bzw. Bit 0/1 = 0) kann `0x5F`
/// sein. Ist der Inhalt kein druckbares ASCII oder zu lang, ist der Rahmen
/// ungültig – nie wird aus halben Antworten eine Kennung.
GsIStand leseGsIRahmen(List<int> bytes) {
  final kopf = bytes.indexOf(gsIKopf);
  if (kopf < 0) return const GsIUnvollstaendig();
  final inhalt = StringBuffer();
  for (var i = kopf + 1; i < bytes.length; i++) {
    final byte = bytes[i];
    if (byte == gsIEnde) {
      final text = inhalt.toString().trim();
      return text.isEmpty
          ? const GsIUngueltig('leerer Rahmen')
          : GsIGueltig(text);
    }
    if (byte < 0x20 || byte > 0x7E) {
      return GsIUngueltig(
        'nicht druckbares Zeichen 0x${byte.toRadixString(16)}',
      );
    }
    if (inhalt.length >= gsIMaxLaenge) {
      return const GsIUngueltig('zu lang');
    }
    inhalt.writeCharCode(byte);
  }
  return const GsIUnvollstaendig();
}
