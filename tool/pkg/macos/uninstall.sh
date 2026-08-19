#!/usr/bin/env bash
# Entfernt Kasseneck Connect von einem Mac.
#
#   sudo bash tool/pkg/macos/uninstall.sh
#
# macOS-Pakete bringen keinen Deinstallierer mit — das hier ist er. Der
# Autostart gehört dem angemeldeten Benutzer, die Dateien liegen unter
# /usr/local; deshalb braucht das Skript sudo und wechselt für den
# Autostart-Teil in die Sitzung des Benutzers.
#
# Die Konfiguration (~/Library/Application Support/KasseneckConnect) bleibt
# absichtlich liegen: dort stehen die gekoppelten Kassen und die Drucker.
# Mit `--purge` fliegt auch sie weg.
set -u

INSTALL_DIR="/usr/local/kasseneck-connect"
BINARY="$INSTALL_DIR/kasseneck-connect"
LABEL="at.kasseneck.connect"
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 64 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte mit sudo starten: sudo bash $0" >&2
  exit 1
fi

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"

# 1. Autostart des angemeldeten Benutzers abräumen.
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
  CONSOLE_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory \
    | /usr/bin/awk '{print $2}')"

  if [ -x "$BINARY" ] && [ -n "$CONSOLE_HOME" ]; then
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
      /usr/bin/env HOME="$CONSOLE_HOME" "$BINARY" uninstall-autostart || true
  fi

  # Gürtel und Hosenträger, falls die Binary schon weg ist.
  /bin/launchctl bootout "gui/$CONSOLE_UID/$LABEL" 2>/dev/null || true
  /bin/rm -f "$CONSOLE_HOME/Library/LaunchAgents/$LABEL.plist"
  echo "Autostart von $CONSOLE_USER entfernt."
fi

# 2. Dateien und Symlink.
/bin/rm -f /usr/local/bin/kasseneck-connect
/bin/rm -rf "$INSTALL_DIR"
echo "Programmdateien entfernt."

# 3. Den Installationsvermerk löschen, sonst hält macOS das Paket für
#    installiert und ein erneuter Lauf des Installers verhält sich als Update.
/usr/sbin/pkgutil --forget "$LABEL" >/dev/null 2>&1 || true
echo "Paketvermerk ($LABEL) entfernt."

if [ "$PURGE" -eq 1 ] && [ -n "${CONSOLE_HOME:-}" ]; then
  /bin/rm -rf "$CONSOLE_HOME/Library/Application Support/KasseneckConnect"
  echo "Konfiguration und Log entfernt."
else
  echo "Konfiguration bleibt liegen (--purge entfernt sie mit)."
fi

echo "Fertig."
