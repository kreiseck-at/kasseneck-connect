#!/usr/bin/env bash
# Baut Connect für macOS in der Architektur des bauenden Rechners.
#
#   tool/build_macos.sh   -> build/Kasseneck Connect.app
#                            build/kasseneck-connect-macos-arm64
#                            (bzw. …-macos-x64 auf Intel)
#
# Ausgeliefert wird das App-Paket: die Dart-Binary als Hauptprogramm, daneben
# in Contents/MacOS das Bluetooth-Hilfsprogramm (Swift, CoreBluetooth), dazu
# Info.plist (tool/macos/Info.plist.in) und Symbol (tool/macos/AppIcon.icns).
# Die nackte Binary bleibt als Artefakt liegen.
#
# `dart compile exe` kann nicht für eine fremde Architektur bauen: Apple
# Silicon liefert arm64, ein Intel-Mac x64. Für beide Architekturen braucht es
# zwei Läufe auf zwei Rechnern (die CI baut nur arm64 auf macos-15).
#
# Signiert wird, sobald der Schlüsselbund eine Developer-ID-Application-
# Identität hergibt (`KASSENECK_SIGN_APP` sticht die Suche). Ohne Zertifikat —
# so ist es auf den CI-Runnern — bleiben Binary und Paket unsigniert und der
# Lauf geht mit einer Warnung weiter; ausgeliefert wird ohnehin nur, was auf
# dem Entwicklungsrechner entsteht (siehe README, „Signierung & Notarisierung“).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

DART="${DART:-dart}"
SWIFT="${SWIFT:-swift}"
ARCH="$(normalize_arch)"
VERSION="$(pubspec_version)"
OUT="build/$(binary_name macos "$ARCH")"
APP="build/$APP_BUNDLE_NAME"
HELPER_PACKAGE="native/macos/KasseneckBluetooth"

mkdir -p build
"$DART" pub get
"$DART" compile exe bin/kasseneck_connect.dart -o "$OUT"
chmod +x "$OUT"

# Das Hilfsprogramm. Gestartet wird es hier nie: es meldet sich sofort bei
# CoreBluetooth an, und macOS fragte dann im Namen des Terminals.
"$SWIFT" build -c release --package-path "$HELPER_PACKAGE" --product kasseneck-bluetooth
HELPER_BIN="$("$SWIFT" build -c release --package-path "$HELPER_PACKAGE" --show-bin-path)"

# Das Paket immer frisch zusammensetzen: ein Rest aus einem älteren Lauf
# landete sonst mit in der Signatur.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/@VERSION@/$VERSION/g" tool/macos/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp "$OUT" "$APP/Contents/MacOS/kasseneck-connect"
cp "$HELPER_BIN/kasseneck-bluetooth" "$APP/Contents/MacOS/kasseneck-bluetooth"
cp tool/macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod 755 "$APP/Contents/MacOS/kasseneck-connect" "$APP/Contents/MacOS/kasseneck-bluetooth"
# Erweiterte Attribute (Quarantäne, Finder-Infos) weist codesign ab.
xattr -cr "$APP"

# `--options runtime` (Hardened Runtime) und `--timestamp` (Zeitstempel von
# Apple) sind beide Pflicht, sonst weist die Notarisierung das Paket ab. Die
# Berechtigungsdatei ist genauso Pflicht: ohne sie startet die Binary unter
# Hardened Runtime überhaupt nicht mehr (Begründung steht in der Datei).
# Die nackte Binary wird für sich signiert, das Paket mit sign_app_bundle
# (Reihenfolge und Begründung stehen dort).
SIGN_APP="${KASSENECK_SIGN_APP:-$(find_signing_identity 'Developer ID Application' codesigning || true)}"
if [ -n "$SIGN_APP" ]; then
  echo "Signiere: $SIGN_APP"
  codesign --force --options runtime --timestamp \
    --entitlements tool/entitlements-macos.plist \
    --sign "$SIGN_APP" "$OUT"
  codesign --verify --strict --verbose=2 "$OUT"
  sign_app_bundle "$APP" "$SIGN_APP"
  warn_app_cert_expiry "$APP"
else
  echo "Warnung: keine Developer-ID-Application-Identität gefunden — Binary und App-Paket bleiben unsigniert." >&2
fi

# Startprobe: eine falsch signierte Binary schießt der Kernel wortlos ab
# (SIGKILL, Rückgabewert 137). Das darf nicht erst dem Kunden auffallen.
echo "Startprobe: $("$OUT" version)"
echo "Startprobe im Paket: $("$APP/Contents/MacOS/kasseneck-connect" version)"

echo "Fertig: $OUT"
ls -lh "$OUT"
echo "Fertig: $APP"
du -sh "$APP"
