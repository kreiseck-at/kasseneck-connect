#!/usr/bin/env bash
# Veröffentlicht die gebauten Dateien als GitHub Release.
#
#   tool/release.sh --dry-run     # nur zeigen, was passieren würde
#   tool/release.sh               # wirklich veröffentlichen
#
# Der Lauf ist **von Hand** gedacht und läuft nicht in der CI: er braucht eine
# angemeldete `gh` (`gh auth login`) mit Schreibrecht auf das Repo.
#
# Warum GitHub Releases statt Firebase Storage: der Storage-Bucket hält
# Kundendaten und darf nicht öffentlich lesbar sein. Das Repo hier ist
# öffentlich — damit liefert es kostenlos stabile Download-Adressen, ohne dass
# irgendwo ein Bucket-Präfix freigeschaltet werden müsste.
#
# Jede Datei landet als Release-Asset **ohne** Version im Namen — die vier
# Namen sind fest verlinkt (README, Kasse ab v1.2 für die Selbstaktualisierung):
#
#   KasseneckConnect-macos-arm64.pkg
#   KasseneckConnect-macos-x64.pkg
#   KasseneckConnect-windows-x64.exe
#   KasseneckConnect-linux-x64.deb
#
# Die Build-Skripte legen sie versioniert in `build/` ab; hier werden sie vor
# dem Hochladen in die unversionierten Namen kopiert. Dazu kommt `latest.json`
# (Feed für den Selbstaustausch ab v1.2) mit den Schlüsseln `darwin-arm64`,
# `darwin-x64`, `windows-x64`, `linux-x64` — die URLs zeigen auf
# `releases/download/v<version>/<unversionierter Name>`. Die Kasse selbst
# verlinkt `releases/latest/download/<name>` (siehe lib/src/downloads.dart) —
# das löst GitHub immer auf das jeweils letzte Release auf, ganz ohne Feed.
#
# Die vier Namen stehen zusätzlich in `lib/src/downloads.dart` und in der
# README-Tabelle; `test/downloads_test.dart` prüft, dass alle drei Stellen
# dasselbe sagen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

REPO="${REPO:-kreiseck-at/kasseneck-connect}"
VERSION="$(pubspec_version)"
TAG="v$VERSION"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 64 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh (GitHub CLI) wurde nicht gefunden — https://cli.github.com" >&2
  exit 70
fi

# Ein zweiter Lauf mit derselben Version darf nicht stillschweigend über ein
# bestehendes Release drüberbügeln.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG existiert bereits auf $REPO." >&2
  echo "Version in pubspec.yaml erhöhen oder das bestehende Release von Hand löschen." >&2
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
MISSING=()
for key in "${FEED_KEYS[@]}"; do
  candidate="build/$(file_for_key "$key")"
  if [ -f "$candidate" ]; then
    PRESENT+=("$key")
  else
    MISSING+=("$key")
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
  base="$(basename "$candidate")"
  case "$base" in
    *-"$VERSION"-*) ;;
    # Die unversionierten Kopien erzeugt dieses Skript selbst (auch im
    # Trockenlauf) — sie sind kein Fremdbestand und werden gleich überschrieben.
    KasseneckConnect-macos-*.pkg|KasseneckConnect-windows-*.exe|KasseneckConnect-linux-*.deb) ;;
    *) STALE+=("$candidate") ;;
  esac
done

if [ "${#STALE[@]}" -gt 0 ]; then
  echo "In build/ liegen Dateien einer anderen Version als $VERSION:" >&2
  for file in "${STALE[@]}"; do echo "  $file" >&2; done
  echo "Bitte 'rm -rf build' und neu bauen — sonst gehen alte Binaries mit hoch." >&2
  exit 70
fi

# Unversionierte Kopien anlegen — das sind die eigentlichen Release-Assets.
ASSET_FILES=()
for key in "${PRESENT[@]}"; do
  name="$(file_for_key "$key")"
  latest="$(strip_version "$name" "$VERSION")"
  cp -f "build/$name" "build/$latest"
  ASSET_FILES+=("build/$latest")
done

# latest.json zusammenbauen.
FEED="build/latest.json"
{
  echo '{'
  echo "  \"version\": \"$VERSION\","
  echo "  \"notes\": \"${NOTES:-}\","
  echo '  "files": {'
  first=1
  for key in "${PRESENT[@]}"; do
    name="$(file_for_key "$key")"
    latest="$(strip_version "$name" "$VERSION")"
    file="build/$latest"
    [ "$first" -eq 0 ] && echo ','
    first=0
    printf '    "%s": {\n' "$key"
    printf '      "url": "https://github.com/%s/releases/download/%s/%s",\n' "$REPO" "$TAG" "$latest"
    printf '      "sha256": "%s",\n' "$(sha256_of "$file")"
    printf '      "size": %s\n' "$(size_of "$file")"
    printf '    }'
  done
  echo
  echo '  }'
  echo '}'
} > "$FEED"
ASSET_FILES+=("$FEED")

echo "== $FEED =="
cat "$FEED"
echo

# Release-Notes aus dem Changelog-Abschnitt dieser Version ziehen — sonst
# steht am Release nirgends, was in der Fassung steckt.
NOTES_FILE="build/RELEASE_NOTES.md"
awk -v ver="$VERSION" '
  $0 ~ "^## " ver "([[:space:]]|$)" { found=1; next }
  found && /^## / { found=0 }
  found { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$NOTES_FILE"

if [ ! -s "$NOTES_FILE" ]; then
  echo "Warnung: kein Changelog-Abschnitt für $VERSION gefunden — Release-Notes bleiben leer." >&2
  echo "Kasseneck Connect $VERSION." > "$NOTES_FILE"
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

run gh release create "$TAG" --repo "$REPO" --title "$TAG" --notes-file "$NOTES_FILE" "${ASSET_FILES[@]}"

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo
  echo "Ausgelassen (fehlten in build/):" >&2
  for key in "${MISSING[@]}"; do
    echo "  $key ($(file_for_key "$key"))" >&2
  done
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Nur Probelauf — es wurde nichts veröffentlicht."
else
  echo
  echo "Version $VERSION veröffentlicht: https://github.com/$REPO/releases/tag/$TAG"
fi
