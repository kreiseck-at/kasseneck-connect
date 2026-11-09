# Gemeinsame Hilfen der Build- und Release-Skripte. Wird per `source` geladen.
#
# **Eine Namensregel für alles, was ausgeliefert wird:**
#
#   KasseneckConnect-<version>-<os>-<arch>.<endung>
#
# und unter `connect/latest/` dieselbe Datei **ohne** Version:
#
#   KasseneckConnect-<os>-<arch>.<endung>
#
# Genau diese vier Namen verlinkt die Kasse fest (Download-Abschnitt), sie
# stehen in `lib/src/downloads.dart`, in der README-Tabelle und werden von
# `test/downloads_test.dart` gegen beides festgenagelt:
#
#   KasseneckConnect-macos-arm64.pkg
#   KasseneckConnect-macos-x64.pkg
#   KasseneckConnect-windows-x64.exe
#   KasseneckConnect-linux-x64.deb

# Vereinheitlicht die Architekturnamen der Systeme: `uname -m` sagt auf Intel
# `x86_64`, auf Linux-ARM `aarch64`. Ausgeliefert wird überall `x64`/`arm64`.
normalize_arch() {
  case "${1:-$(uname -m)}" in
    x86_64 | amd64) echo "x64" ;;
    arm64 | aarch64) echo "arm64" ;;
    *) echo "${1:-$(uname -m)}" ;;
  esac
}

# Version aus der pubspec.yaml (die einzige Quelle; `lib/src/version.dart`
# wird von `test/downloads_test.dart` dagegen geprüft).
pubspec_version() {
  awk '/^version:/ {print $2; exit}' "${1:-pubspec.yaml}"
}

# Name der Binary, wie sie beim Kompilieren entsteht (Eingang der Paketierung,
# kein Auslieferungsname).
binary_name() {
  local os="$1" arch="$2"
  if [ "$os" = "windows" ]; then
    echo "kasseneck-connect-$os-$arch.exe"
  else
    echo "kasseneck-connect-$os-$arch"
  fi
}

# Auslieferungsname mit Version.
release_name() {
  local version="$1" os="$2" arch="$3" ext="$4"
  echo "KasseneckConnect-$version-$os-$arch.$ext"
}

# Derselbe Name ohne Version — so heißt die Datei unter `connect/latest/`.
strip_version() {
  local name="$1" version="$2"
  echo "${name/-$version-/-}"
}

# Sucht eine Signaturidentität im Schlüsselbund und gibt ihren vollständigen
# Namen aus — genau so, wie ihn `codesign --sign` bzw. `productsign --sign`
# erwartet:
#
#   find_signing_identity "Developer ID Application" codesigning
#   find_signing_identity "Developer ID Installer"
#
# Ohne Treffer bleibt die Ausgabe leer und der Rückgabewert 1; die
# Build-Skripte bauen dann unsigniert weiter (CI-Runner haben kein
# Zertifikat). Die Installer-Identität taucht in der Richtlinie `codesigning`
# nicht auf — deshalb ist die Richtlinie ein eigener, optionaler Parameter.
find_signing_identity() {
  local prefix="$1" policy="${2:-}" line=""
  command -v security >/dev/null 2>&1 || return 1
  if [ -n "$policy" ]; then
    line="$(security find-identity -v -p "$policy" 2>/dev/null | grep "\"$prefix" | head -1)" || true
  else
    line="$(security find-identity -v 2>/dev/null | grep "\"$prefix" | head -1)" || true
  fi
  [ -n "$line" ] || return 1
  # Zeilenform: `  4) <SHA1> "Developer ID Application: Firma (TEAMID)"`
  printf '%s\n' "$line" | sed -e 's/^[^"]*"//' -e 's/"[^"]*$//'
}

# Ordnername des App-Pakets unter macOS. Den zeigt macOS im Bluetooth-Dialog
# und in den Systemeinstellungen (nicht CFBundleName) — deshalb mit
# Leerzeichen, und deshalb steht jeder Pfad, der ihn enthält, in
# Anführungszeichen (geprüft von test/macos_bundle_test.dart).
APP_BUNDLE_NAME="Kasseneck Connect.app"

# Signiert das App-Paket $1 mit der Identität $2 (Hardened Runtime +
# Zeitstempel, beides Pflicht für die Notarisierung).
#
# Die Reihenfolge ist fest: erst das Hilfsprogramm in Contents/MacOS, dann
# das Paket. Die Paketsignatur versiegelt alles darin und setzt dafür
# signierten Inhalt voraus; sie signiert dabei die Hauptbinary (die
# Dart-Binary) mit `tool/entitlements-macos.plist`, ohne die sie unter
# Hardened Runtime nicht startet. Das Hilfsprogramm (Swift) braucht keine
# Berechtigung; die Bluetooth-Freigabe hängt am Paket.
sign_app_bundle() {
  local bundle="$1" identity="$2"
  codesign --force --options runtime --timestamp \
    --sign "$identity" "$bundle/Contents/MacOS/kasseneck-bluetooth"
  codesign --force --options runtime --timestamp \
    --entitlements tool/entitlements-macos.plist \
    --sign "$identity" "$bundle"
  codesign --verify --strict --deep --verbose=2 "$bundle"
}

# Ob das App-Paket $1 gültig und mit einer Developer-ID-Application-Identität
# signiert ist (nicht nur ad hoc vom Linker).
signed_with_developer_id() {
  local bundle="$1"
  codesign --verify --strict --deep "$bundle" 2>/dev/null || return 1
  # grep ohne -q: es liest bis zum Ende, sonst kann codesign unter pipefail
  # an einem geschlossenen Rohr scheitern.
  codesign -dv --verbose=2 "$bundle" 2>&1 \
    | grep '^Authority=Developer ID Application' >/dev/null
}

# Team-ID von Post Now e.U. im Apple Developer Program. Dieselbe Prüfung wie
# im Agenten vor dem Ein-Klick-Update (lib/src/update/mac_package.dart,
# `connectTeamId`): was die Skripte durchlassen, nimmt auch der Agent an.
CONNECT_TEAM_ID="6KMT4H4CNE"

# Ab so vielen Tagen vor dem Ablauf warnen die Skripte vor dem
# Signierzertifikat. Ein neues Zertifikat braucht Zeit (Apple-Konto,
# Schlüsselbund, Probebau), und nach dem Ablauf lässt sich nicht mehr signieren.
CERT_WARN_DAYS="${KASSENECK_CERT_WARN_DAYS:-60}"

# Ob das .pkg $1 so signiert ist, wie der Agent es vor dem Ein-Klick-Update
# verlangt: gültige Signatur eines Developer-ID-Zertifikats, das Blatt der
# Kette ist „Developer ID Installer“ unseres Teams, die Kette endet bei
# „Apple Root CA“. Gibt bei Misserfolg den Grund auf stderr aus.
pkg_developer_id_signed() {
  local pkg="$1" out=""
  if ! out="$(pkgutil --check-signature "$pkg" 2>&1)"; then
    echo "  pkgutil: keine gültige Signatur." >&2
    return 1
  fi
  # grep ohne -q: es liest bis zum Ende (pipefail, siehe oben).
  if ! printf '%s\n' "$out" \
      | grep 'Status: signed by a developer certificate issued by Apple for distribution' >/dev/null; then
    echo "  pkgutil: nicht mit einem Developer-ID-Zertifikat signiert." >&2
    return 1
  fi
  if ! printf '%s\n' "$out" \
      | grep -E "^[[:space:]]*1\.[[:space:]]+Developer ID Installer: .+ \($CONNECT_TEAM_ID\)[[:space:]]*$" >/dev/null; then
    echo "  pkgutil: nicht mit „Developer ID Installer … ($CONNECT_TEAM_ID)“ signiert." >&2
    return 1
  fi
  if ! printf '%s\n' "$out" \
      | grep -E '^[[:space:]]*[0-9]+\.[[:space:]]+Apple Root CA[[:space:]]*$' >/dev/null; then
    echo "  pkgutil: die Kette endet nicht bei „Apple Root CA“." >&2
    return 1
  fi
}

# Ob Gatekeeper das .pkg $1 als notarisiertes Paket unseres Teams annimmt
# (`spctl`, wie der Agent vor dem Ein-Klick-Update).
pkg_notarized() {
  local pkg="$1" out=""
  if ! out="$(spctl -a -t install -vv "$pkg" 2>&1)"; then
    echo "  spctl: Gatekeeper lehnt das Paket ab." >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | grep 'source=Notarized Developer ID' >/dev/null; then
    echo "  spctl: nicht als „Notarized Developer ID“ angenommen." >&2
    return 1
  fi
  if ! printf '%s\n' "$out" \
      | grep -E "^origin=Developer ID Installer: .+ \($CONNECT_TEAM_ID\)[[:space:]]*$" >/dev/null; then
    echo "  spctl: Herkunft ist nicht „Developer ID Installer … ($CONNECT_TEAM_ID)“." >&2
    return 1
  fi
}

# Sekunden seit 1970 für ein UTC-Datum „JJJJ-MM-TT hh:mm:ss“ (BSD- und
# GNU-date).
utc_epoch() {
  TZ=UTC0 date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null \
    || TZ=UTC0 date -d "$1" +%s 2>/dev/null
}

# Warnt, wenn das Zertifikat $1 (Bezeichnung) am $2 („JJJJ-MM-TT hh:mm:ss“,
# UTC) in weniger als CERT_WARN_DAYS Tagen abläuft oder schon abgelaufen ist.
# $3 ersetzt im Test die Uhr (Sekunden seit 1970). Bricht nie ab.
warn_cert_expiry() {
  local name="$1" expires="$2" now="${3:-$(date -u +%s)}" end="" days=0
  if ! end="$(utc_epoch "$expires")" || [ -z "$end" ]; then
    echo "Warnung: Ablaufdatum von „${name}“ nicht lesbar: $expires" >&2
    return 0
  fi
  days=$(( (end - now) / 86400 ))
  if [ "$end" -le "$now" ]; then
    echo "WARNUNG: Das Zertifikat „${name}“ ist am ${expires%% *} abgelaufen – damit lässt sich nicht mehr signieren." >&2
  elif [ "$days" -lt "$CERT_WARN_DAYS" ]; then
    echo "WARNUNG: Das Zertifikat „${name}“ läuft am ${expires%% *} ab, in $days Tagen." >&2
    echo "         Rechtzeitig im Apple-Developer-Konto ein neues ausstellen und in den Schlüsselbund holen." >&2
  fi
  return 0
}

# Warnt vor dem Ablauf der Zertifikate, mit denen das .pkg $1 signiert ist
# (Blatt und Zwischenstelle; die Zeilen „Expires:“ von pkgutil, in UTC).
warn_pkg_cert_expiry() {
  local pkg="$1" out="" line="" n=0 name="" expires=""
  out="$(pkgutil --check-signature "$pkg" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "$line" in
      *[0-9]'. '*)
        name="$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*[0-9]*\.[[:space:]]*//')"
        n=$((n + 1)) ;;
      *'Expires: '*)
        expires="$(printf '%s\n' "$line" | sed -e 's/^.*Expires: //' -e 's/ [+-][0-9]*$//')"
        # Die Wurzel von Apple erneuert Apple selbst.
        [ "$name" = "Apple Root CA" ] || warn_cert_expiry "$name" "$expires" ;;
    esac
  done <<EOF_KETTE
$out
EOF_KETTE
  [ "$n" -gt 0 ] || echo "Warnung: keine Zertifikatskette in der Signatur von $pkg gefunden." >&2
  return 0
}

# Warnt vor dem Ablauf der Zertifikate, mit denen das App-Paket bzw. die
# Binary $1 signiert ist (codesign legt sie als DER ab, openssl prüft).
warn_app_cert_expiry() {
  local target="$1" dir="" cert="" name="" ende=""
  command -v codesign >/dev/null 2>&1 || return 0
  command -v openssl >/dev/null 2>&1 || return 0
  dir="$(mktemp -d)"
  if codesign -d --extract-certificates="$dir/zert" "$target" >/dev/null 2>&1; then
    for cert in "$dir"/zert*; do
      [ -f "$cert" ] || continue
      name="$(openssl x509 -inform DER -in "$cert" -noout -subject 2>/dev/null \
        | sed -e 's/.*CN *= *\([^,/]*\).*/\1/')"
      [ "$name" = "Apple Root CA" ] && continue
      ende="$(openssl x509 -inform DER -in "$cert" -noout -enddate 2>/dev/null \
        | sed -e 's/^notAfter=//')"
      if ! openssl x509 -inform DER -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
        echo "WARNUNG: Das Zertifikat „${name:-?}“ ist abgelaufen ($ende) – damit lässt sich nicht mehr signieren." >&2
      elif ! openssl x509 -inform DER -in "$cert" -noout \
          -checkend $((CERT_WARN_DAYS * 86400)) >/dev/null 2>&1; then
        echo "WARNUNG: Das Zertifikat „${name:-?}“ läuft in weniger als $CERT_WARN_DAYS Tagen ab ($ende)." >&2
        echo "         Rechtzeitig im Apple-Developer-Konto ein neues ausstellen und in den Schlüsselbund holen." >&2
      fi
    done
  fi
  rm -rf "$dir"
  return 0
}

# Name eines Testbaus: nie ein Auslieferungsname, damit er nie in ein Release
# gerät (tool/release.sh sucht nur nach release_name).
testbau_name() {
  local version="$1" os="$2" arch="$3" ext="$4"
  echo "KasseneckConnect-$version-$os-$arch-testbau.$ext"
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
