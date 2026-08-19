#!/usr/bin/env bash
# Baut die macOS-Binary für die Architektur des bauenden Rechners.
#
#   tool/build_macos.sh            -> build/kasseneck-connect-macos-arm64
#
# `dart compile exe` kann nicht für eine fremde Architektur bauen: Apple
# Silicon liefert arm64, ein Intel-Mac x64. Für beide Architekturen braucht es
# zwei Läufe auf zwei Rechnern (in der CI: macos-14 und macos-13).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DART="${DART:-dart}"
ARCH="$(uname -m)"
OUT="build/kasseneck-connect-macos-$ARCH"

mkdir -p build
"$DART" pub get
"$DART" compile exe bin/kasseneck_connect.dart -o "$OUT"
chmod +x "$OUT"

echo "Fertig: $OUT"
ls -lh "$OUT"
