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
