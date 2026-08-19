#!/usr/bin/env bash
# Baut die Linux-Binary für die Architektur des bauenden Rechners.
#
#   tool/build_linux.sh            -> build/kasseneck-connect-linux-x64
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DART="${DART:-dart}"
case "$(uname -m)" in
  x86_64) ARCH="x64" ;;
  aarch64 | arm64) ARCH="arm64" ;;
  *) ARCH="$(uname -m)" ;;
esac
OUT="build/kasseneck-connect-linux-$ARCH"

mkdir -p build
"$DART" pub get
"$DART" compile exe bin/kasseneck_connect.dart -o "$OUT"
chmod +x "$OUT"

echo "Fertig: $OUT"
ls -lh "$OUT"
