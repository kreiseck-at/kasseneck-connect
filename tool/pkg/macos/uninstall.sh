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
# immer; macOS fragt dabei nach Kennwort oder Touch ID. Die aktuelle Stelle
# nimmt es erst aus dem Anmelde-Schlüsselbund, wenn ihr nachweislich nicht
# mehr vertraut wird – sonst bleibt sie stehen, und das Skript nennt den
# Befehl, mit dem der Benutzer das Vertrauen selbst entzieht. Fremde
# Zertifikate bleiben unberührt.
#
# Ab 1.3 liegt die Binary im App-Paket `Kasseneck Connect.app` im
# Installationsordner; das Paket geht mit dem Ordner, und die
# Bluetooth-Freigabe des Pakets nimmt das Skript zurück.
#
# Die Konfiguration (~/Library/Application Support/KasseneckConnect) bleibt
# absichtlich liegen: dort stehen die gekoppelten Kassen, die Drucker und die
# Zertifikate (`tls/`). Mit `--purge` fliegt auch sie weg.
set -u

INSTALL_DIR="/usr/local/kasseneck-connect"
BINARY="$INSTALL_DIR/Kasseneck Connect.app/Contents/MacOS/kasseneck-connect"
LABEL="at.kasseneck.connect"
BUNDLE_ID="at.kasseneck.connect"
CA_NAME="Kasseneck Connect (lokal)"
PURGE=0
CERT_DIR=""
CA_TRUST_LEFT=0

# >>> Schlüsselbund und Bluetooth (geprüft von test/uninstall_script_test.dart)
#
# Was hier den Schlüsselbund oder die Datenschutz-Freigaben anfasst, läuft
# über as_console_user (unten, in der Sitzung des angemeldeten Benutzers).
# Der Test setzt dafür eine eigene Funktion ein und gibt die Ergebnisse vor;
# das Skript selbst kennt keinen anderen Weg.

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

# Die Fingerabdrücke aus $1 (durch Leerraum getrennt) ohne $2.
without_hash() {
  printf '%s\n' "$1" | /usr/bin/awk -v drop="$2" '
    { for (i = 1; i <= NF; i++) if ($i != drop) printf "%s ", $i }'
}

# Legt unter $1 den Arbeitsordner CERT_DIR für die PEM-Dateien an und räumt
# ihn beim Ende des Skripts weg, auch nach einem Fehler oder Abbruch.
#
# `security` läuft als Benutzer und muss die Dateien lesen können. Der
# TMPDIR von root (Start über sudo oder über das Admin-Fenster) liegt aber
# unter /var/folders/… mit Rechten 0700: remove-trusted-cert scheiterte dort
# still. Das Skript nimmt deshalb /private/tmp; mktemp legt den Ordner
# exklusiv an, 755 lässt jeden lesen, schreiben kann nur root.
make_cert_dir() {
  CERT_DIR="$(/usr/bin/mktemp -d "$1/kasseneck-connect-deinstall.XXXXXX")" \
    || { CERT_DIR=""; return 1; }
  trap remove_cert_dir EXIT
  trap 'exit 130' HUP INT TERM
  /bin/chmod 755 "$CERT_DIR"
}

remove_cert_dir() {
  if [ -n "${CERT_DIR:-}" ]; then
    /bin/rm -rf "$CERT_DIR"
  fi
  CERT_DIR=""
}

# Kopiert die Datei $1 nach $2, lesbar für jeden.
readable_copy() {
  /bin/cp "$1" "$2" && /bin/chmod 644 "$2"
}

# Nennt den Befehl, mit dem der Benutzer der Stelle $1 selbst das Vertrauen
# entzieht.
manual_untrust_hint() {
  echo "         Ihr Zertifikat bleibt deshalb im Anmelde-Schlüsselbund. Vertrauen selbst"
  echo "         entziehen (im Terminal des angemeldeten Benutzers, ohne sudo):"
  echo "         security remove-trusted-cert \"$1\""
}

# Entzieht den Stellen von Connect das Vertrauen und nimmt die aktuelle
# Stelle aus dem Anmelde-Schlüsselbund $1 – aber nur, wenn ihr danach
# nachweislich nicht mehr vertraut wird. $2 ist der Ordner tls/ der
# Konfiguration (ca-cert.pem, server-cert.pem), $3 der Ort für den
# Arbeitsordner. Setzt CA_TRUST_LEFT=1, wenn das Vertrauen in die aktuelle
# Stelle nicht nachweislich weg ist.
#
# Die aktuelle Stelle verliert ihr Vertrauen immer über ihre eigene Datei
# ca-cert.pem, nie über das Zertifikat aus dem Schlüsselbund – so auch dann,
# wenn es dort schon fehlt und nur der Vertrauenseintrag übrig ist. Geprüft
# wird danach wie im Agenten (isLocalCaTrusted). Beide Aufrufe bekommen
# lesbare Kopien im Arbeitsordner: eine Datei, die der Benutzer nicht lesen
# kann, ergäbe sonst „nicht vertraut“ und damit ein Löschen. Ein Zertifikat zu
# löschen, dem noch vertraut wird, hinterließe genau so einen verwaisten
# Eintrag: macOS wendet ihn weiter an, zeigt ihn aber nirgends mehr.
untrust_local_ca() {
  local keychain="$1" ca="$2/ca-cert.pem" server="$2/server-cert.pem"
  local ca_sha1="" wanted older pem found=0 removed=0 state=ungeprueft
  CA_TRUST_LEFT=0

  if ! make_cert_dir "$3"; then
    echo "WARNUNG: Kein Arbeitsordner unter $3 – am Vertrauen in die lokale"
    echo "         Zertifizierungsstelle hat sich nichts geändert."
    if [ -f "$ca" ]; then
      CA_TRUST_LEFT=1
      manual_untrust_hint "$ca"
    fi
    return 0
  fi
  if [ -f "$ca" ]; then
    ca_sha1="$(sha1_of "$ca")"
  fi

  # Ältere Stellen: Bezeichnung genau der Name, aber nicht die aktuelle.
  wanted="$(as_console_user /usr/bin/security find-certificate -a -Z \
              -c "$CA_NAME" "$keychain" 2>/dev/null \
            | exact_label_hashes "$CA_NAME")"
  older="$(without_hash "$wanted" "$ca_sha1")"
  if [ -n "${older// /}" ]; then
    /bin/mkdir -m 755 "$CERT_DIR/aeltere"
    as_console_user /usr/bin/security find-certificate -a -Z -p \
        -c "$CA_NAME" "$keychain" 2>/dev/null \
      | write_pems "$CERT_DIR/aeltere" "$older"
    for pem in "$CERT_DIR"/aeltere/*.pem; do
      [ -f "$pem" ] || continue
      /bin/chmod 644 "$pem"
      found=$((found + 1))
      if as_console_user /usr/bin/security remove-trusted-cert "$pem" \
           >/dev/null 2>&1; then
        removed=$((removed + 1))
      fi
    done
    echo "Ältere Stellen von Connect im Schlüsselbund: $found, Vertrauen entzogen bei $removed."
  fi

  if [ ! -f "$ca" ]; then
    remove_cert_dir
    echo "Keine lokale Zertifizierungsstelle in der Konfiguration – nichts weiter zu entziehen."
    return 0
  fi

  if readable_copy "$ca" "$CERT_DIR/ca-cert.pem"; then
    as_console_user /usr/bin/security remove-trusted-cert "$CERT_DIR/ca-cert.pem" \
      >/dev/null 2>&1 || true
    if [ -f "$server" ] && readable_copy "$server" "$CERT_DIR/server-cert.pem"; then
      if as_console_user /usr/bin/security verify-cert \
           -c "$CERT_DIR/server-cert.pem" -c "$CERT_DIR/ca-cert.pem" \
           -p ssl -L -q >/dev/null 2>&1; then
        state=vertraut
      else
        state=entzogen
      fi
    fi
  fi
  remove_cert_dir

  case "$state" in
    entzogen)
      echo "Vertrauen in die lokale Zertifizierungsstelle entzogen (nachgeprüft)."
      # Gelöscht wird nur die eigene Stelle: das Zertifikat mit genau dem
      # Fingerabdruck von ca-cert.pem.
      if [ -n "$ca_sha1" ] \
         && as_console_user /usr/bin/security delete-certificate -Z "$ca_sha1" \
              "$keychain" >/dev/null 2>&1; then
        echo "Zertifikat der Stelle aus dem Anmelde-Schlüsselbund entfernt."
      fi
      ;;
    vertraut)
      CA_TRUST_LEFT=1
      echo "WARNUNG: Der lokalen Zertifizierungsstelle wird weiterhin vertraut"
      echo "         (Abfrage abgebrochen oder abgelehnt?)."
      manual_untrust_hint "$ca"
      ;;
    *)
      CA_TRUST_LEFT=1
      echo "WARNUNG: Ob der lokalen Zertifizierungsstelle noch vertraut wird, ließ"
      echo "         sich nicht prüfen (server-cert.pem fehlt, oder eine der Dateien in"
      echo "         tls/ ist nicht lesbar)."
      manual_untrust_hint "$ca"
      ;;
  esac
}

# Setzt die Bluetooth-Freigabe des App-Pakets mit der Kennung $1 zurück; sie
# hängt an der Kennung und bliebe sonst in den Systemeinstellungen stehen.
# Ohne Frage.
reset_bluetooth() {
  if as_console_user /usr/bin/tccutil reset BluetoothAlways "$1" \
       >/dev/null 2>&1; then
    echo "Bluetooth-Freigabe zurückgesetzt."
  else
    echo "WARNUNG: Die Bluetooth-Freigabe ließ sich nicht zurücksetzen. Von Hand:"
    echo "         Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth,"
    echo "         „Kasseneck Connect“ entfernen."
  fi
}

# <<< Schlüsselbund und Bluetooth

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
  #     Stelle (nur nachgeprüft) aus dem Anmelde-Schlüsselbund nehmen,
  # 1b. die Bluetooth-Freigabe zurücksetzen. Beides gehört dem Benutzer,
  #     also in seiner Sitzung; Fehlschläge halten die Deinstallation nicht
  #     auf, die Ausgabe nennt sie.
  if [ -n "$CONSOLE_HOME" ]; then
    as_console_user() {
      /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
        /usr/bin/env HOME="$CONSOLE_HOME" "$@"
    }
    untrust_local_ca "$CONSOLE_HOME/Library/Keychains/login.keychain-db" \
      "$CONSOLE_HOME/Library/Application Support/KasseneckConnect/tls" \
      /private/tmp
    reset_bluetooth "$BUNDLE_ID"
  fi
fi

# 2. Dateien und Symlink; der Ordner enthält auch das App-Paket.
/bin/rm -f /usr/local/bin/kasseneck-connect
/bin/rm -rf "$INSTALL_DIR"
echo "Programmdateien entfernt."

# 3. Den Installationsvermerk löschen, sonst hält macOS das Paket für
#    installiert und ein erneuter Lauf des Installers verhält sich als Update.
/usr/sbin/pkgutil --forget "$LABEL" >/dev/null 2>&1 || true
echo "Paketvermerk ($LABEL) entfernt."

if [ "$PURGE" -eq 1 ] && [ -n "${CONSOLE_HOME:-}" ]; then
  if [ "$CA_TRUST_LEFT" -eq 1 ]; then
    # Der Befehl oben braucht tls/ca-cert.pem.
    echo "WARNUNG: Konfiguration und Zertifikate bleiben trotz --purge liegen, bis der"
    echo "         Stelle nicht mehr vertraut wird; danach das Skript erneut mit --purge starten."
  else
    /bin/rm -rf "$CONSOLE_HOME/Library/Application Support/KasseneckConnect"
    echo "Konfiguration, Zertifikate und Log entfernt."
  fi
else
  echo "Konfiguration und Zertifikate bleiben liegen (--purge entfernt sie mit)."
fi

echo "Fertig."
