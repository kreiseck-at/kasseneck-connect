#!/usr/bin/env bash
# Baut die macOS-Binary für die Architektur des bauenden Rechners.
#
#   tool/build_macos.sh            -> build/kasseneck-connect-macos-arm64
#                                     bzw. …-macos-x64 auf Intel
#
# `dart compile exe` kann nicht für eine fremde Architektur bauen: Apple
# Silicon liefert arm64, ein Intel-Mac x64. Für beide Architekturen braucht es
# zwei Läufe auf zwei Rechnern (in der CI: macos-14 und macos-13).
#
# Signiert wird, sobald der Schlüsselbund eine Developer-ID-Application-
# Identität hergibt (`KASSENECK_SIGN_APP` sticht die Suche). Ohne Zertifikat —
# so ist es auf den CI-Runnern — bleibt die Binary unsigniert und der Lauf
# geht mit einer Warnung weiter; ausgeliefert wird ohnehin nur, was auf dem
# Entwicklungsrechner entsteht (siehe README, „Signierung & Notarisierung“).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

DART="${DART:-dart}"
ARCH="$(normalize_arch)"
OUT="build/$(binary_name macos "$ARCH")"

mkdir -p build
"$DART" pub get
"$DART" compile exe bin/kasseneck_connect.dart -o "$OUT"
chmod +x "$OUT"

# `--options runtime` (Hardened Runtime) und `--timestamp` (Zeitstempel von
# Apple) sind beide Pflicht, sonst weist die Notarisierung das Paket ab. Die
# Berechtigungsdatei ist genauso Pflicht: ohne sie startet die Binary unter
# Hardened Runtime überhaupt nicht mehr (Begründung steht in der Datei).
SIGN_APP="${KASSENECK_SIGN_APP:-$(find_signing_identity 'Developer ID Application' codesigning || true)}"
if [ -n "$SIGN_APP" ]; then
  echo "Signiere: $SIGN_APP"
  codesign --force --options runtime --timestamp \
    --entitlements tool/entitlements-macos.plist \
    --sign "$SIGN_APP" "$OUT"
  codesign --verify --strict --verbose=2 "$OUT"
  # Startprobe: eine falsch signierte Binary schießt der Kernel wortlos ab
  # (SIGKILL, Rückgabewert 137). Das darf nicht erst dem Kunden auffallen.
  echo "Startprobe: $("$OUT" version)"
else
  echo "Warnung: keine Developer-ID-Application-Identität gefunden — Binary bleibt unsigniert." >&2
fi

echo "Fertig: $OUT"
ls -lh "$OUT"
