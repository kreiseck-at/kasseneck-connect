#!/usr/bin/env bash
# Baut die Linux-Binary für die Architektur des bauenden Rechners.
#
#   tool/build_linux.sh            -> build/kasseneck-connect-linux-x64
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

DART="${DART:-dart}"
ARCH="$(normalize_arch)"
OUT="build/$(binary_name linux "$ARCH")"

mkdir -p build
"$DART" pub get
"$DART" compile exe bin/kasseneck_connect.dart -o "$OUT"
chmod +x "$OUT"

echo "Fertig: $OUT"
ls -lh "$OUT"
