#!/usr/bin/env bash
# Baut das macOS-Installationspaket aus der bereits kompilierten Binary.
#
#   tool/build_macos.sh && tool/pkg/macos/build_pkg.sh
#   -> build/KasseneckConnect-<version>-macos-<arch>.pkg
#
# Das Paket ist **unsigniert** (v1.0): kein Developer-ID-Zertifikat, keine
# Notarisierung. Beim ersten Öffnen meldet sich Gatekeeper; die Anleitung dazu
# steht in der README. `pkgbuild` selbst braucht weder sudo noch Zertifikat.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

VERSION="$(awk '/^version:/ {print $2; exit}' pubspec.yaml)"
ARCH="${ARCH:-$(uname -m)}"
BINARY="build/kasseneck-connect-macos-$ARCH"
IDENTIFIER="at.kasseneck.connect"
INSTALL_DIR="/usr/local/kasseneck-connect"
PKG="build/KasseneckConnect-$VERSION-macos-$ARCH.pkg"

if [ ! -x "$BINARY" ]; then
  echo "Binary fehlt: $BINARY — zuerst tool/build_macos.sh laufen lassen." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SCRIPTS"' EXIT

# 1. Nutzlast: die Binary landet unter /usr/local/kasseneck-connect/.
mkdir -p "$STAGE$INSTALL_DIR"
cp "$BINARY" "$STAGE$INSTALL_DIR/kasseneck-connect"
chmod 755 "$STAGE$INSTALL_DIR/kasseneck-connect"
# Erweiterte Attribute weg — vor allem `com.apple.quarantine`, das die
# heruntergeladene Binary sonst mit ins Paket schleppt.
# `com.apple.provenance` setzt macOS selbst und lässt sich nicht entfernen;
# pkgbuild legt dafür AppleDouble-Einträge (`._kasseneck-connect`) in die
# Nutzlast. Die sind harmlos: der Installer wertet sie aus und legt sie nicht
# auf die Platte.
xattr -cr "$STAGE"

# 2. Postinstall: den Autostart als **angemeldeter Benutzer** einrichten.
#    Der Installer läuft als root; ein LaunchAgent gehört aber in die Sitzung
#    des Benutzers (~/Library/LaunchAgents). `launchctl asuser` wechselt in
#    dessen Sitzung, `sudo -u` in dessen Benutzerkonto — beides ist nötig,
#    damit HOME und die GUI-Domäne stimmen.
cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -u

BINARY="/usr/local/kasseneck-connect/kasseneck-connect"
CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
  echo "Kein angemeldeter Benutzer — Autostart bitte von Hand einrichten:"
  echo "  $BINARY install-autostart"
  exit 0
fi

CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"

# `install-autostart` schreibt den LaunchAgent und lädt ihn; `RunAtLoad`
# startet den Agenten dabei gleich mit.
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
  "$BINARY" install-autostart || {
    echo "Autostart ließ sich nicht einrichten — bitte von Hand:"
    echo "  $BINARY install-autostart"
  }

exit 0
POSTINSTALL
chmod 755 "$SCRIPTS/postinstall"

mkdir -p build
pkgbuild \
  --root "$STAGE" \
  --scripts "$SCRIPTS" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  "$PKG"

echo "Fertig: $PKG"
ls -lh "$PKG"
