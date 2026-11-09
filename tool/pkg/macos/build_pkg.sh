#!/usr/bin/env bash
# Baut das macOS-Installationspaket aus dem fertigen App-Paket.
#
#   tool/build_macos.sh && tool/pkg/macos/build_pkg.sh
#   -> build/KasseneckConnect-<version>-macos-<arch>.pkg
#
# Das .pkg legt `Kasseneck Connect.app` unter /usr/local/kasseneck-connect/
# ab, dazu den Symlink /usr/local/kasseneck-connect/kasseneck-connect auf die
# Binary im Paket (dort lag sie bis 1.2.x; ältere Handgriffe und Anleitungen
# treffen sie so weiter).
#
# Signiert wird zweistufig, sobald der Schlüsselbund die Zertifikate hergibt
# (ab v1.0.2 der Regelfall, `KASSENECK_SIGN_APP`/`KASSENECK_SIGN_PKG` stechen
# die Suche):
#
#   1. das App-Paket in der Nutzlast mit der **Developer-ID-Application**-
#      Identität (Hardened Runtime + Zeitstempel) — `pkgbuild` signiert den
#      Inhalt nicht mit, das .pkg ist nur die Hülle. Das erledigt schon
#      `tool/build_macos.sh`; hier wird nur nachgezogen, wenn das App-Paket
#      ohne Developer-ID-Signatur ankommt;
#   2. das fertige .pkg mit der **Developer-ID-Installer**-Identität über
#      `productsign` — `pkgbuild --sign` könnte das auch, aber der Umweg über
#      eine unsignierte Zwischendatei hält den Auslieferungsnamen frei von
#      halbfertigen Ständen.
#
# Ohne beide Signaturen bricht das Skript ab: unter dem Auslieferungsnamen
# steht nur ein Paket, das der Agent beim Ein-Klick-Update annehmen würde
# (Developer ID Installer des Teams, App-Paket mit Developer ID Application).
# Notarisiert wird danach mit `tool/notarize_macos.sh`; die Notarisierung prüft
# `tool/release.sh` und bricht ohne sie ebenfalls ab.
#
#   tool/pkg/macos/build_pkg.sh --testbau
#   -> build/KasseneckConnect-<version>-macos-<arch>-testbau.pkg
#
# Für Bauproben ohne Zertifikat (CI-Runner, Rechner ohne Schlüsselbund) gibt
# es `--testbau`: dann darf das Paket unsigniert bleiben, heißt aber nie wie
# eine Auslieferung — tool/release.sh sucht nur die Auslieferungsnamen und
# fände es nicht. `pkgbuild` selbst braucht weder sudo noch Zertifikat.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
# shellcheck source=tool/_common.sh
. tool/_common.sh

TESTBAU=0
for arg in "$@"; do
  case "$arg" in
    --testbau) TESTBAU=1 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 64 ;;
  esac
done

VERSION="$(pubspec_version)"
ARCH="$(normalize_arch "${ARCH:-}")"
APP="build/$APP_BUNDLE_NAME"
IDENTIFIER="at.kasseneck.connect"
INSTALL_DIR="/usr/local/kasseneck-connect"
if [ "$TESTBAU" -eq 1 ]; then
  PKG="build/$(testbau_name "$VERSION" macos "$ARCH" pkg)"
else
  PKG="build/$(release_name "$VERSION" macos "$ARCH" pkg)"
fi

# Bricht einen Auslieferungsbau mit Grund ab. Ein Testbau warnt nur.
ohne_signatur() {
  if [ "$TESTBAU" -eq 1 ]; then
    echo "Warnung (Testbau): $1" >&2
    return 0
  fi
  echo "Abbruch: $1" >&2
  echo "Ein Paket ohne Developer-ID-Signatur nimmt weder Gatekeeper noch das Ein-Klick-Update an." >&2
  echo "Zertifikate: README, „Signierung & Notarisierung“. Bauprobe ohne Zertifikat: $0 --testbau" >&2
  exit 1
}

if [ ! -x "$APP/Contents/MacOS/kasseneck-connect" ] \
   || [ ! -x "$APP/Contents/MacOS/kasseneck-bluetooth" ]; then
  echo "App-Paket fehlt oder ist unvollständig: $APP — zuerst tool/build_macos.sh laufen lassen." >&2
  exit 1
fi

# Vorab, damit ein Auslieferungsbau nicht erst nach dem ganzen Lauf scheitert:
# ohne Installer-Identität entsteht nie ein signiertes Paket.
SIGN_PKG="${KASSENECK_SIGN_PKG:-$(find_signing_identity 'Developer ID Installer' || true)}"
if [ -z "$SIGN_PKG" ]; then
  ohne_signatur "keine Developer-ID-Installer-Identität im Schlüsselbund."
fi

STAGE="$(mktemp -d)"
SCRIPTS="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SCRIPTS" "$WORK"' EXIT

# 1. Nutzlast: das App-Paket unter /usr/local/kasseneck-connect/, daneben der
#    Symlink an der alten Stelle der Binary (relativ, zeigt ins Paket).
#    `ditto` übernimmt das Paket samt Signatur unverändert.
STAGED_APP="$STAGE$INSTALL_DIR/$APP_BUNDLE_NAME"
mkdir -p "$STAGE$INSTALL_DIR"
ditto "$APP" "$STAGED_APP"
ln -s "$APP_BUNDLE_NAME/Contents/MacOS/kasseneck-connect" "$STAGE$INSTALL_DIR/kasseneck-connect"
# Erweiterte Attribute weg — vor allem `com.apple.quarantine`, das ein
# heruntergeladenes Paket sonst mit ins .pkg schleppt. Die Signatur deckt sie
# nicht ab.
# `com.apple.provenance` setzt macOS selbst und lässt sich nicht entfernen;
# pkgbuild legt dafür AppleDouble-Einträge (`._kasseneck-connect`) in die
# Nutzlast. Die sind harmlos: der Installer wertet sie aus und legt sie nicht
# auf die Platte.
xattr -cr "$STAGE"

# 1a. Signatur der Nutzlast. Ist das App-Paket schon mit Developer ID
#     signiert (der Regelfall nach tool/build_macos.sh), bleibt es, wie es
#     ist; eine zweite Signatur brächte nur einen neuen Zeitstempel.
SIGN_APP="${KASSENECK_SIGN_APP:-$(find_signing_identity 'Developer ID Application' codesigning || true)}"
if signed_with_developer_id "$STAGED_APP"; then
  echo "Nutzlast ist bereits signiert."
elif [ -n "$SIGN_APP" ]; then
  sign_app_bundle "$STAGED_APP" "$SIGN_APP"
  echo "Nutzlast signiert: $SIGN_APP"
fi
if signed_with_developer_id "$STAGED_APP"; then
  warn_app_cert_expiry "$STAGED_APP"
else
  ohne_signatur "das App-Paket in der Nutzlast trägt keine gültige Developer-ID-Application-Signatur."
fi
# Startprobe aus der Nutzlast heraus, über den Symlink: ins Paket darf nur
# eine Binary, die auch wirklich startet (Hardened Runtime ohne
# Berechtigungen = SIGKILL).
"$STAGE$INSTALL_DIR/kasseneck-connect" version >/dev/null

# 2. Postinstall: Symlink in den PATH, dann als **angemeldeter Benutzer**
#    Autostart und Vertrauen in die lokale Zertifizierungsstelle (HTTPS).
cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/bash
set -u

# Die Binary im App-Paket. Von hier startet sie der LaunchAgent: macOS ordnet
# die Bluetooth-Freigabe dem Paket zu, und das Hilfsprogramm liegt daneben.
BINARY="/usr/local/kasseneck-connect/Kasseneck Connect.app/Contents/MacOS/kasseneck-connect"

# Damit `kasseneck-connect doctor` und `… pair` ohne vollen Pfad laufen. `-h`
# ersetzt einen vorhandenen Symlink, statt ihm zu folgen.
/bin/mkdir -p /usr/local/bin
/bin/ln -sfh "$BINARY" /usr/local/bin/kasseneck-connect

CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
  echo "Kasseneck Connect: kein angemeldeter Benutzer an der Konsole."
  echo "Kasseneck Connect: Autostart und HTTPS-Zertifikat bitte selbst einrichten:"
  echo "  kasseneck-connect install-autostart"
  echo "  kasseneck-connect zertifikat-vertrauen"
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
  echo "Kasseneck Connect: Autostart und HTTPS-Zertifikat bitte selbst einrichten:"
  echo "  kasseneck-connect install-autostart"
  echo "  kasseneck-connect zertifikat-vertrauen"
  exit 0
fi

# `install-autostart` schreibt den LaunchAgent auf die Binary im Paket und
# lädt ihn; `RunAtLoad` startet den Agenten dabei gleich mit. Beim Update von
# 1.2.x ersetzt das den alten Eintrag und beendet den alten Agenten.
# Konfiguration, Kopplungen und Drucker liegen im Benutzerverzeichnis und
# bleiben. Ein Fehlschlag darf die Installation nicht abbrechen — die Binary
# liegt dann trotzdem richtig.
if /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
     /usr/bin/env HOME="$CONSOLE_HOME" "$BINARY" install-autostart; then
  echo "Kasseneck Connect: Autostart für $CONSOLE_USER eingerichtet."
else
  echo "Kasseneck Connect: Autostart ließ sich nicht einrichten."
  echo "Kasseneck Connect: bitte als $CONSOLE_USER von Hand nachholen:"
  echo "  kasseneck-connect install-autostart"
fi

# Safari lässt https://kasse.kasseneck.at nur über HTTPS an 127.0.0.1. Dafür
# muss der lokalen Zertifizierungsstelle einmal vertraut werden; macOS fragt
# den angemeldeten Benutzer dabei nach Kennwort oder Touch ID (Absender
# „security“). Ist sie schon vertraut (Update), fragt es nicht noch einmal.
# Fehlen die Zertifikate noch, legt der Befehl sie an — gleichzeitig mit dem
# eben gestarteten Agenten, die Sperrdatei ordnet das. Bleibt die Frage drei
# Minuten unbeantwortet, beendet der Befehl sie und sich selbst — der
# Installer hängt nie. Ein Fehlschlag bricht die Installation nicht ab:
# HTTP läuft trotzdem, und das Vertrauen lässt sich nachholen.
if /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
     /usr/bin/env HOME="$CONSOLE_HOME" "$BINARY" zertifikat-vertrauen; then
  echo "Kasseneck Connect: Zertifikat für HTTPS ist vertraut."
else
  echo "Kasseneck Connect: dem Zertifikat für HTTPS wird noch nicht vertraut."
  echo "Kasseneck Connect: bitte als $CONSOLE_USER im Terminal nachholen"
  echo "Kasseneck Connect: (macOS fragt dann nach dem Kennwort oder Touch ID):"
  echo "  kasseneck-connect zertifikat-vertrauen"
fi

exit 0
POSTINSTALL
chmod 755 "$SCRIPTS/postinstall"

mkdir -p build

# 3. Paket bauen — erst in eine Zwischendatei, damit unter dem
#    Auslieferungsnamen nie ein unsigniertes Paket steht.
#
#    pkgbuild hält App-Pakete von sich aus für verschiebbar: der Installer
#    sucht dann nach einem Paket mit derselben Kennung (etwa einer Kopie in
#    einem Bauordner) und installiert DORTHIN statt nach /usr/local. Und mit
#    Versionsprüfung ließe er ein vorhandenes neueres Paket stehen, während
#    postinstall trotzdem läuft. Beides wird für jedes Paket der Nutzlast
#    abgeschaltet: das .pkg legt immer genau seinen Stand an seinen Ort.
COMPONENTS="$WORK/components.plist"
pkgbuild --analyze --root "$STAGE" "$COMPONENTS"
i=0
while plutil -extract "$i" xml1 -o /dev/null "$COMPONENTS" 2>/dev/null; do
  plutil -replace "$i.BundleIsRelocatable" -bool NO "$COMPONENTS"
  plutil -replace "$i.BundleIsVersionChecked" -bool NO "$COMPONENTS"
  i=$((i + 1))
done
if [ "$i" -eq 0 ]; then
  echo "pkgbuild --analyze fand kein App-Paket in der Nutzlast." >&2
  exit 1
fi

UNSIGNED="$WORK/unsigned.pkg"
pkgbuild \
  --root "$STAGE" \
  --component-plist "$COMPONENTS" \
  --scripts "$SCRIPTS" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  "$UNSIGNED"

# 4. Paketsignatur — erst in die Arbeitsmappe, unter den Auslieferungsnamen
#    nur, was die Prüfung besteht (dieselbe wie im Agenten vor dem
#    Ein-Klick-Update, ohne die Notarisierung, die erst danach kommt).
rm -f "$PKG"
SIGNED="$WORK/signed.pkg"
if [ -n "$SIGN_PKG" ]; then
  productsign --sign "$SIGN_PKG" "$UNSIGNED" "$SIGNED"
  echo "Paket signiert: $SIGN_PKG"
  pkgutil --check-signature "$SIGNED"
  if pkg_developer_id_signed "$SIGNED"; then
    warn_pkg_cert_expiry "$SIGNED"
  else
    ohne_signatur "die Signatur des Pakets besteht die Prüfung nicht (siehe oben)."
  fi
  mv "$SIGNED" "$PKG"
else
  cp "$UNSIGNED" "$PKG"
  echo "Warnung (Testbau): das Paket bleibt unsigniert – Gatekeeper blockt es beim Kunden." >&2
fi

echo "Fertig: $PKG"
ls -lh "$PKG"
