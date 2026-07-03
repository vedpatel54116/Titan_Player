#!/bin/bash
set -euo pipefail

# locate-deps.sh — Detect libass Homebrew prefix and write an xcconfig fragment.
# Called as an Xcode pre-build script (via XcodeGen preBuildScripts).
# Writes to ${DERIVED_FILE_DIR}/TitanPlayerDeps.xcconfig

PREFIX=""

# 1. Ask Homebrew directly
if command -v brew &>/dev/null; then
  PREFIX="$(brew --prefix libass 2>/dev/null || true)"
fi

# 2. Fallback: probe common locations
if [[ -z "$PREFIX" || ! -d "$PREFIX/include" ]]; then
  for candidate in /opt/homebrew /usr/local; do
    if [[ -d "$candidate/include/ass" ]]; then
      PREFIX="$candidate"
      break
    fi
  done
fi

if [[ -z "$PREFIX" || ! -d "$PREFIX/include" ]]; then
  echo "error: libass not found. Install it with 'brew install libass'." >&2
  echo "  brew install libass" >&2
  exit 1
fi

echo "→ libass prefix: ${PREFIX}"

XCCONFIG="${DERIVED_FILE_DIR}/TitanPlayerDeps.xcconfig"
mkdir -p "$(dirname "$XCCONFIG")"

cat > "$XCCONFIG" <<EOF
HEADER_SEARCH_PATHS = \$(inherited) ${PREFIX}/include
LIBRARY_SEARCH_PATHS = \$(inherited) ${PREFIX}/lib
OTHER_LDFLAGS = \$(inherited) -lass
EOF

echo "→ Wrote ${XCCONFIG}"
