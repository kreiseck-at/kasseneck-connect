#!/usr/bin/env bash
# Reicht ein fertig signiertes .pkg bei Apple zur Notarisierung ein und heftet
# das Ticket ans Paket („stapeln"), damit es auch auf einem Rechner ohne
# Internetzugang durch Gatekeeper kommt.
#
#   tool/notarize_macos.sh build/KasseneckConnect-1.0.2-macos-arm64.pkg
#
# Gebraucht wird ein Schlüsselbund-Profil für `notarytool` (Vorgabename
# `kasseneck-connect`, überschreibbar mit `KASSENECK_NOTARY_PROFILE`). Angelegt
# wird es einmalig mit einem app-spezifischen Kennwort der Apple-ID:
#
#   xcrun notarytool store-credentials kasseneck-connect \
#     --apple-id "<apple-id>" --team-id 6KMT4H4CNE --password "<app-kennwort>"
#
# Reihenfolge ist bindend: erst `tool/pkg/macos/build_pkg.sh` (signiert), dann
# dieses Skript, dann `tool/release.sh`. Wer das Paket nach dem Stapeln noch
# einmal anfasst, wirft das Ticket weg.
#
# Rückgabewerte: 64 = falscher Aufruf, 69 = kein Schlüsselbund-Profil (das
# wertet `tool/release.sh` als „übersprungen"), 70 = Notarisierung
# fehlgeschlagen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG="${1:-}"
PROFILE="${KASSENECK_NOTARY_PROFILE:-kasseneck-connect}"

if [ -z "$PKG" ]; then
  echo "Aufruf: tool/notarize_macos.sh <paket.pkg>" >&2
  exit 64
fi

if [ ! -f "$PKG" ]; then
  echo "Paket nicht gefunden: $PKG" >&2
  exit 64
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun fehlt — die Notarisierung braucht die Xcode-Kommandozeilenwerkzeuge." >&2
  exit 69
fi

# Das Profil liegt als generisches Kennwort im Anmeldeschlüsselbund. Die
# Abfrage ist eine reine Vorprüfung ohne Netz; sie sagt bloß, ob es sich
# überhaupt lohnt, `notarytool` zu starten.
if ! security find-generic-password -s 'com.apple.gke.notary.tool' -a "$PROFILE" >/dev/null 2>&1; then
  # Klammern um den Namen: das schließende Anführungszeichen ist mehrbytig und
  # zöge sonst in den Variablennamen hinein.
  echo "Kein notarytool-Profil „${PROFILE}“ im Schlüsselbund." >&2
  echo "Einmalig anlegen:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE \\" >&2
  echo "    --apple-id \"<apple-id>\" --team-id 6KMT4H4CNE --password \"<app-kennwort>\"" >&2
  exit 69
fi

# Ohne Signatur ist die Einreichung von vornherein vergebens.
if ! pkgutil --check-signature "$PKG" >/dev/null 2>&1; then
  echo "Das Paket ist nicht signiert: $PKG" >&2
  echo "Apple nimmt nur signierte Pakete an — zuerst tool/pkg/macos/build_pkg.sh mit Zertifikat laufen lassen." >&2
  exit 70
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

echo "Reiche ein: $PKG (Profil: $PROFILE)"
STATUS=0
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$LOG" || STATUS=$?

# `notarytool --wait` endet auch bei „Invalid" mit 0, sobald die Einreichung
# selbst geklappt hat — der Status steht nur in der Ausgabe.
if [ "$STATUS" -eq 0 ] && ! grep -q '^ *status: Accepted' "$LOG"; then
  STATUS=70
fi

if [ "$STATUS" -ne 0 ]; then
  SUBMISSION="$(awk '/^ *id: /{print $2; exit}' "$LOG")"
  if [ -n "$SUBMISSION" ]; then
    echo >&2
    echo "== Prüfbericht von Apple ($SUBMISSION) ==" >&2
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
  fi
  echo "Notarisierung fehlgeschlagen: $PKG" >&2
  exit 70
fi

# Das Ticket ins Paket schreiben und gleich nachsehen, ob es hält.
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

echo "Notarisiert und gestapelt: $PKG"
