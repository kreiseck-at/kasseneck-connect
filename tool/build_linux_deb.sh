#!/usr/bin/env bash
# Schnürt aus der Linux-Binary ein minimales Debian-Paket.
#
#   tool/build_linux.sh && tool/build_linux_deb.sh
#   -> build/KasseneckConnect-<version>-linux-<arch>.deb
#
# Das Paket legt die Binary nach /usr/local/kasseneck-connect/, verlinkt sie
# nach /usr/local/bin/kasseneck-connect und richtet im `postinst` den
# Autostart für den angemeldeten Benutzer ein (systemd --user). Es ist
# **unsigniert**.
#
# Gebaut wird nur, wenn `dpkg-deb` vorhanden ist — auf einem Mac ist es das in
# aller Regel nicht; dort überspringt das Skript den Bau mit einem Hinweis
# (Exitcode 0), damit ein Build-Durchlauf nicht daran scheitert. Das echte
# `.deb` entsteht in der CI auf ubuntu-latest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb nicht gefunden — das .deb wird übersprungen."
  echo "(Auf Debian/Ubuntu ist es Teil von dpkg; gebaut wird es in der CI.)"
  exit 0
fi

VERSION="$(pubspec_version)"
ARCH="$(normalize_arch)"
BINARY="build/$(binary_name linux "$ARCH")"
DEB="build/$(release_name "$VERSION" linux "$ARCH" deb)"
INSTALL_DIR="/usr/local/kasseneck-connect"

# Debian benennt Architekturen anders als wir.
case "$ARCH" in
  x64) DEB_ARCH="amd64" ;;
  arm64) DEB_ARCH="arm64" ;;
  *) DEB_ARCH="$ARCH" ;;
esac

if [ ! -x "$BINARY" ]; then
  echo "Binary fehlt: $BINARY — zuerst tool/build_linux.sh laufen lassen." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE$INSTALL_DIR" "$STAGE/usr/local/bin"
install -m 755 "$BINARY" "$STAGE$INSTALL_DIR/kasseneck-connect"
ln -sf "$INSTALL_DIR/kasseneck-connect" "$STAGE/usr/local/bin/kasseneck-connect"

INSTALLED_SIZE="$(du -sk "$STAGE$INSTALL_DIR" | awk '{print $1}')"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: kasseneck-connect
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Kreiseck – Software Solutions <hello@kasseneck.at>
Installed-Size: $INSTALLED_SIZE
Homepage: https://kasseneck.at
Description: Kasseneck Connect — lokaler Agent der Browser-Kasse
 Findet Netzwerk-Bondrucker und druckt die Beleg-Bytes der Kasse
 über TCP 9100 bzw. Epson ePOS. Lauscht ausschließlich auf 127.0.0.1.
CONTROL

# Der Autostart ist eine systemd-User-Unit und gehört damit dem angemeldeten
# Benutzer, nicht root. `postinst` läuft als root — deshalb wird der Befehl
# ausdrücklich in dessen Sitzung und mit dessen HOME ausgeführt.
cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

BINARY="/usr/local/kasseneck-connect/kasseneck-connect"
TARGET_USER="${SUDO_USER:-}"

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  echo "Kein angemeldeter Benutzer erkannt — Autostart bitte selbst einrichten:"
  echo "  kasseneck-connect install-autostart"
  exit 0
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"

su - "$TARGET_USER" -c \
  "XDG_RUNTIME_DIR=/run/user/$TARGET_UID HOME=$TARGET_HOME $BINARY install-autostart" || {
    echo "Autostart ließ sich nicht einrichten — bitte selbst:"
    echo "  kasseneck-connect install-autostart"
  }

exit 0
POSTINST
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e

TARGET_USER="${SUDO_USER:-}"
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  su - "$TARGET_USER" -c \
    "/usr/local/kasseneck-connect/kasseneck-connect uninstall-autostart" || true
fi

exit 0
PRERM
chmod 755 "$STAGE/DEBIAN/prerm"

mkdir -p build
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"

echo "Fertig: $DEB"
ls -lh "$DEB"
