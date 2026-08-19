#!/usr/bin/env bash
# Veröffentlicht die gebauten Dateien im Update-Feed.
#
#   tool/release.sh --dry-run     # nur zeigen, was passieren würde
#   tool/release.sh               # wirklich hochladen
#
# Der Lauf ist **von Hand** gedacht und läuft nicht in der CI: er braucht eine
# angemeldete gcloud (`gcloud auth login`) mit Schreibrecht auf den Bucket.
# Hochgeladen wird nach
#   gs://kasseneck.appspot.com/connect/<version>/…
# und zusätzlich als „latest" nach
#   gs://kasseneck.appspot.com/connect/latest/…
#   gs://kasseneck.appspot.com/connect/latest.json
#
# `latest.json` ist der Feed, den der Agent ab v1.2 beim Selbstaustausch liest:
# Version, Anmerkungen und je Datei URL, SHA-256 und Größe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUCKET="${BUCKET:-gs://kasseneck.appspot.com}"
PREFIX="connect"
PUBLIC_BASE="${PUBLIC_BASE:-https://storage.googleapis.com/kasseneck.appspot.com}"
VERSION="$(awk '/^version:/ {print $2; exit}' pubspec.yaml)"
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

# Ordnet einer Datei ihren Schlüssel im Feed zu.
#
# Die nackte Binary trägt den Plattformschlüssel (`darwin-arm64`) — das ist
# die Datei, die der Agent ab v1.2 gegen sich selbst austauscht. Installer
# bekommen `-installer` angehängt; sie sind für Menschen, nicht für den
# Selbstaustausch. Zwei Dateien dürfen nie denselben Schlüssel bekommen,
# sonst steht der Eintrag zweimal in der JSON-Datei.
platform_key() {
  local name platform kind
  name="$(basename "$1")"

  case "$name" in
    *macos-arm64*) platform="darwin-arm64" ;;
    *macos-x86_64* | *macos-x64*) platform="darwin-x64" ;;
    *linux-arm64*) platform="linux-arm64" ;;
    *linux-x64*) platform="linux-x64" ;;
    *windows*) platform="win32-x64" ;;
    *) platform="" ;;
  esac
  [ -z "$platform" ] && { echo ""; return; }

  case "$name" in
    *.pkg | *-setup.exe | *.deb) kind="-installer" ;;
    *) kind="" ;;
  esac

  echo "$platform$kind"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

size_of() {
  # BSD (macOS) und GNU (Linux) haben verschiedene stat-Flaggen.
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(find build -maxdepth 1 -type f \
  \( -name 'kasseneck-connect-*' -o -name '*.pkg' -o -name '*-setup.exe' \) | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "In build/ liegt nichts zum Veröffentlichen." >&2
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
  for file in "${FILES[@]}"; do
    key="$(platform_key "$file")"
    [ -z "$key" ] && continue
    [ "$first" -eq 0 ] && echo ','
    first=0
    printf '    "%s": {\n' "$key"
    printf '      "url": "%s/%s/%s/%s",\n' \
      "$PUBLIC_BASE" "$PREFIX" "$VERSION" "$(basename "$file")"
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

for file in "${FILES[@]}"; do
  run "${COPY[@]}" "$file" "$BUCKET/$PREFIX/$VERSION/$(basename "$file")"
  run "${COPY[@]}" "$file" "$BUCKET/$PREFIX/latest/$(basename "$file")"
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
