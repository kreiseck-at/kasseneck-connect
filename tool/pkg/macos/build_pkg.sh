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
# shellcheck source=tool/_common.sh
. tool/_common.sh

VERSION="$(pubspec_version)"
ARCH="$(normalize_arch "${ARCH:-}")"
BINARY="build/$(binary_name macos "$ARCH")"
IDENTIFIER="at.kasseneck.connect"
INSTALL_DIR="/usr/local/kasseneck-connect"
PKG="build/$(release_name "$VERSION" macos "$ARCH" pkg)"

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

# 2. Postinstall: Symlink in den PATH und Autostart als **angemeldeter
#    Benutzer**.
cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -u

BINARY="/usr/local/kasseneck-connect/kasseneck-connect"

# Damit `kasseneck-connect doctor` und `… pair` ohne vollen Pfad laufen.
/bin/mkdir -p /usr/local/bin
/bin/ln -sf "$BINARY" /usr/local/bin/kasseneck-connect

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
  echo "Kasseneck Connect: kein angemeldeter Benutzer an der Konsole."
  echo "Kasseneck Connect: Autostart bitte selbst einrichten:"
  echo "  kasseneck-connect install-autostart"
  exit 0
fi

CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
# HOME ausdrücklich setzen: `sudo -u` allein lässt HOME auf /var/root stehen,
# der LaunchAgent landete dann in /var/root/Library/LaunchAgents und würde nie
# geladen. `-H` setzt HOME aus der Benutzerdatenbank, und `env HOME=…` macht
# es auch dann richtig, wenn die sudo-Konfiguration `-H` ignoriert.
CONSOLE_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory \
  | /usr/bin/awk '{print $2}')"

if [ -z "$CONSOLE_HOME" ] || [ ! -d "$CONSOLE_HOME" ]; then
  echo "Kasseneck Connect: Benutzerverzeichnis von $CONSOLE_USER nicht gefunden."
  echo "Kasseneck Connect: Autostart bitte selbst einrichten:"
  echo "  kasseneck-connect install-autostart"
  exit 0
fi

# `install-autostart` schreibt den LaunchAgent und lädt ihn; `RunAtLoad`
# startet den Agenten dabei gleich mit. Ein Fehlschlag darf die Installation
# nicht abbrechen — die Binary liegt dann trotzdem richtig.
if /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
     /usr/bin/env HOME="$CONSOLE_HOME" "$BINARY" install-autostart; then
  echo "Kasseneck Connect: Autostart für $CONSOLE_USER eingerichtet."
else
  echo "Kasseneck Connect: Autostart ließ sich nicht einrichten."
  echo "Kasseneck Connect: bitte als $CONSOLE_USER von Hand nachholen:"
  echo "  kasseneck-connect install-autostart"
fi

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
