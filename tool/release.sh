#!/usr/bin/env bash
# Veröffentlicht die gebauten Dateien im Update-Feed.
#
#   tool/release.sh --dry-run     # nur zeigen, was passieren würde
#   tool/release.sh               # wirklich hochladen
#
# Der Lauf ist **von Hand** gedacht und läuft nicht in der CI: er braucht eine
# angemeldete gcloud (`gcloud auth login`) mit Schreibrecht auf den Bucket.
#
# Hochgeladen wird jede Datei zweimal:
#   gs://…/connect/<version>/KasseneckConnect-<version>-<os>-<arch>.<ext>
#   gs://…/connect/latest/KasseneckConnect-<os>-<arch>.<ext>
#
# Die zweite Adresse ist die, die die **Kasse fest verlinkt** — sie darf sich
# nie ändern. Die vier Namen stehen zusätzlich in `lib/src/downloads.dart` und
# in der README-Tabelle; `test/downloads_test.dart` prüft, dass alle drei
# Stellen dasselbe sagen:
#
#   KasseneckConnect-macos-arm64.pkg
#   KasseneckConnect-macos-x64.pkg
#   KasseneckConnect-windows-x64.exe
#   KasseneckConnect-linux-x64.deb
#
# `latest.json` (Feed für den Selbstaustausch ab v1.2) trägt die Schlüssel
# `darwin-arm64`, `darwin-x64`, `windows-x64`, `linux-x64` mit URLs auf
# `connect/<version>/…` — versioniert, damit ein Update reproduzierbar bleibt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

BUCKET="${BUCKET:-gs://kasseneck.appspot.com}"
PREFIX="connect"
PUBLIC_BASE="${PUBLIC_BASE:-https://storage.googleapis.com/kasseneck.appspot.com}"
VERSION="$(pubspec_version)"
NOTES="${NOTES:-}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 64 ;;
  esac
done

# Welches Kommando kann Storage? `gcloud storage` ist der Nachfolger von gsutil.
if command -v gcloud >/dev/null 2>&1; then
  COPY=(gcloud storage cp)
elif command -v gsutil >/dev/null 2>&1; then
  COPY=(gsutil cp)
elif [ "$DRY_RUN" -eq 1 ]; then
  COPY=(gcloud storage cp)
else
  echo "Weder gcloud noch gsutil gefunden." >&2
  exit 70
fi

# Plattformschlüssel des Feeds -> Dateiname (mit Version) in build/.
FEED_KEYS=(darwin-arm64 darwin-x64 windows-x64 linux-x64)

file_for_key() {
  case "$1" in
    darwin-arm64) release_name "$VERSION" macos arm64 pkg ;;
    darwin-x64) release_name "$VERSION" macos x64 pkg ;;
    windows-x64) release_name "$VERSION" windows x64 exe ;;
    linux-x64) release_name "$VERSION" linux x64 deb ;;
    *) echo "" ;;
  esac
}

# Was liegt tatsächlich in build/? Ein Release entsteht auf mehreren Rechnern;
# fehlende Plattformen werden übersprungen statt zu scheitern.
PRESENT=()
for key in "${FEED_KEYS[@]}"; do
  candidate="build/$(file_for_key "$key")"
  if [ -f "$candidate" ]; then
    PRESENT+=("$key")
  else
    echo "Hinweis: $candidate fehlt — $key wird ausgelassen." >&2
  fi
done

if [ "${#PRESENT[@]}" -eq 0 ]; then
  echo "In build/ liegt keine einzige Auslieferungsdatei." >&2
  echo "Erwartet wird z. B. build/$(file_for_key darwin-arm64)." >&2
  exit 70
fi

# Fremde Versionen in build/ sind ein Abbruchgrund, kein Schönheitsfehler: die
# nackten Binaries (kasseneck-connect-<os>-<arch>) tragen keine Version im
# Namen. Aus einem nicht geleerten Verzeichnis wanderte die Binary der
# Vorversion unbemerkt in den Ordner der neuen — und wäre ab v1.2 die Grundlage
# des Selbstaustauschs. Vor jedem Release also: `rm -rf build`, dann bauen.
STALE=()
for candidate in build/KasseneckConnect-*; do
  [ -f "$candidate" ] || continue
  case "$(basename "$candidate")" in
    *-"$VERSION"-*) ;;
    *) STALE+=("$candidate") ;;
  esac
done

if [ "${#STALE[@]}" -gt 0 ]; then
  echo "In build/ liegen Dateien einer anderen Version als $VERSION:" >&2
  for file in "${STALE[@]}"; do echo "  $file" >&2; done
  echo "Bitte 'rm -rf build' und neu bauen — sonst gehen alte Binaries mit hoch." >&2
  exit 70
fi

# latest.json zusammenbauen.
FEED="build/latest.json"
{
  echo '{'
  echo "  \"version\": \"$VERSION\","
  echo "  \"notes\": \"$NOTES\","
  echo '  "files": {'
  first=1
  for key in "${PRESENT[@]}"; do
    name="$(file_for_key "$key")"
    file="build/$name"
    [ "$first" -eq 0 ] && echo ','
    first=0
    printf '    "%s": {\n' "$key"
    printf '      "url": "%s/%s/%s/%s",\n' "$PUBLIC_BASE" "$PREFIX" "$VERSION" "$name"
    printf '      "sha256": "%s",\n' "$(sha256_of "$file")"
    printf '      "size": %s\n' "$(size_of "$file")"
    printf '    }'
  done
  echo
  echo '  }'
  echo '}'
} > "$FEED"

echo "== $FEED =="
cat "$FEED"
echo

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

for key in "${PRESENT[@]}"; do
  name="$(file_for_key "$key")"
  latest="$(strip_version "$name" "$VERSION")"
  run "${COPY[@]}" "build/$name" "$BUCKET/$PREFIX/$VERSION/$name"
  run "${COPY[@]}" "build/$name" "$BUCKET/$PREFIX/latest/$latest"
done

# Die nackten Binaries wandern mit in den Versionsordner (Grundlage des
# Selbstaustauschs ab v1.2), aber nicht nach latest/ — die Kasse verlinkt dort
# ausschließlich die Installer.
for binary in build/kasseneck-connect-*; do
  [ -f "$binary" ] || continue
  run "${COPY[@]}" "$binary" "$BUCKET/$PREFIX/$VERSION/$(basename "$binary")"
done

run "${COPY[@]}" "$FEED" "$BUCKET/$PREFIX/$VERSION/latest.json"
run "${COPY[@]}" "$FEED" "$BUCKET/$PREFIX/latest.json"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Nur Probelauf — es wurde nichts hochgeladen."
else
  echo
  echo "Version $VERSION veröffentlicht: $PUBLIC_BASE/$PREFIX/latest.json"
  echo "Hinweis: der Präfix $PREFIX/ muss im Bucket öffentlich lesbar sein."
fi
