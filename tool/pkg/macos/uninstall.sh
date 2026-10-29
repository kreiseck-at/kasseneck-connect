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
# Das Vertrauen in die lokale Zertifizierungsstelle (HTTPS) entzieht es
# immer, die aktuelle Stelle nimmt es aus dem Anmelde-Schlüsselbund; macOS
# fragt dabei nach Kennwort oder Touch ID. Fremde Zertifikate bleiben
# unberührt.
#
# Die Konfiguration (~/Library/Application Support/KasseneckConnect) bleibt
# absichtlich liegen: dort stehen die gekoppelten Kassen, die Drucker und die
# Zertifikate (`tls/`). Mit `--purge` fliegt auch sie weg.
set -u

INSTALL_DIR="/usr/local/kasseneck-connect"
BINARY="$INSTALL_DIR/kasseneck-connect"
LABEL="at.kasseneck.connect"
CA_NAME="Kasseneck Connect (lokal)"
PURGE=0

# >>> Auswahl im Schlüsselbund (geprüft von test/uninstall_script_test.dart)

# SHA-1 jedes Treffers aus `security find-certificate -a -Z` (stdin), dessen
# Bezeichnung GENAU $1 ist. `-c` allein trifft auch jede Bezeichnung, die den
# Namen nur enthält.
exact_label_hashes() {
  /usr/bin/awk -v name="$1" '
    /^SHA-256 hash: / { sha1 = ""; next }
    /^SHA-1 hash: / { sha1 = $3; next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (sha1 != "" && line == "\"labl\"<blob>=\"" name "\"") print sha1
    }'
}

# Schreibt das PEM jedes Treffers aus `security find-certificate -a -Z -p`
# (stdin), dessen SHA-1 in $2 steht (durch Leerzeichen getrennt), nach
# $1/<sha1>.pem.
write_pems() {
  /usr/bin/awk -v dir="$1" -v wanted=" $2 " '
    /^SHA-256 hash: / { sha1 = ""; next }
    /^SHA-1 hash: / { sha1 = $3; next }
    /^-----BEGIN CERTIFICATE-----/ {
      keep = (sha1 != "" && index(wanted, " " sha1 " ") > 0)
    }
    keep { print > (dir "/" sha1 ".pem") }
    /^-----END CERTIFICATE-----/ {
      if (keep) close(dir "/" sha1 ".pem")
      keep = 0
    }'
}

# SHA-1 der PEM-Datei $1 in der Schreibweise von `security` (Großbuchstaben,
# ohne Doppelpunkte); leer, wenn sie sich nicht lesen lässt.
sha1_of() {
  /usr/bin/openssl x509 -noout -fingerprint -sha1 -in "$1" 2>/dev/null \
    | /usr/bin/sed 's/^[^=]*=//; s/://g' | /usr/bin/tr 'abcdef' 'ABCDEF'
}

# <<< Auswahl im Schlüsselbund

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

  # 1a. Vertrauen in die lokale Zertifizierungsstelle entziehen und die
  #     aktuelle Stelle aus dem Anmelde-Schlüsselbund nehmen. Beides gehört
  #     dem Benutzer, also in seiner Sitzung; Fehlschläge (abgebrochene
  #     Frage, nichts eingetragen) halten die Deinstallation nicht auf.
  if [ -n "$CONSOLE_HOME" ]; then
    as_console_user() {
      /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
        /usr/bin/env HOME="$CONSOLE_HOME" "$@"
    }
    CA_CERT="$CONSOLE_HOME/Library/Application Support/KasseneckConnect/tls/ca-cert.pem"
    KEYCHAIN="$CONSOLE_HOME/Library/Keychains/login.keychain-db"
    CA_SHA1=""
    if [ -f "$CA_CERT" ]; then
      CA_SHA1="$(sha1_of "$CA_CERT")"
    fi

    # Vertrauen entziehen — nur Zertifikaten, deren Bezeichnung genau der
    # Name der Stelle ist (auch älteren Stellen nach einer Neuanlage).
    WANTED="$(as_console_user /usr/bin/security find-certificate -a -Z \
                -c "$CA_NAME" "$KEYCHAIN" 2>/dev/null \
              | exact_label_hashes "$CA_NAME" | /usr/bin/tr '\n' ' ')"
    CERT_DIR="$(/usr/bin/mktemp -d)"
    /bin/chmod 755 "$CERT_DIR"
    if [ -n "${WANTED// /}" ]; then
      as_console_user /usr/bin/security find-certificate -a -Z -p \
          -c "$CA_NAME" "$KEYCHAIN" 2>/dev/null \
        | write_pems "$CERT_DIR" "$WANTED"
    fi
    for PEM in "$CERT_DIR"/*.pem; do
      [ -f "$PEM" ] || continue
      /bin/chmod 644 "$PEM"
      as_console_user /usr/bin/security remove-trusted-cert "$PEM" \
        >/dev/null 2>&1 || true
    done
    /bin/rm -rf "$CERT_DIR"
    # Die aktuelle Stelle auch dann, wenn sie nicht (mehr) im Schlüsselbund
    # steht — sonst wäre sie oben schon dabei gewesen.
    if [ -f "$CA_CERT" ] \
       && { [ -z "$CA_SHA1" ] || [ "${WANTED/$CA_SHA1/}" = "$WANTED" ]; }; then
      as_console_user /usr/bin/security remove-trusted-cert "$CA_CERT" \
        >/dev/null 2>&1 || true
    fi

    # Gelöscht wird nur die eigene Stelle: das Zertifikat mit genau dem
    # Fingerabdruck von ca-cert.pem dieses Benutzers.
    if [ -n "$CA_SHA1" ]; then
      as_console_user /usr/bin/security delete-certificate -Z "$CA_SHA1" \
        "$KEYCHAIN" >/dev/null 2>&1 || true
    fi
    echo "Vertrauen in die lokale Zertifizierungsstelle entfernt (soweit eingetragen)."
  fi
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
  echo "Konfiguration, Zertifikate und Log entfernt."
else
  echo "Konfiguration und Zertifikate bleiben liegen (--purge entfernt sie mit)."
fi

echo "Fertig."
