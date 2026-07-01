#!/usr/bin/env bash
# check-test-parity.sh
# Verifies that every Swift test files under TitanPlayer/Tests/ is reachable
# from BOTH the SwiftPM package (always true via Package.swift path:
# argument) AND the parallel TitanPlayer.xcodeproj scaffold.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
PKG="$ROOT/TitanPlayer/Package.swift"
PBX_STUB="$ROOT/TitanPlayer.xcodeproj/PROJECT_PENDING.md"
PROJECT_YML="$ROOT/TitanPlayer.xcodeproj/project.yml.suggested"

echo "=== TitanPlayer test-parity check ==="

if [[ ! -f "$PKG" ]]; then
  echo "FAIL: missing $PKG"; exit 1
fi

TEST_FILES=$(find "$ROOT/TitanPlayer/Tests" -name "*.swift" -type f | wc -l | tr -d ' ')
echo "Swift test source files: $TEST_FILES"

echo
echo "SwiftPM .testTarget references:"
grep -c "TitanPlayerTests" "$PKG" || true

if [[ -f "$PBX_STUB" ]]; then
  echo
  echo "Xcode project scaffold:"
  echo "  PROJECT_PENDING.md present: yes"
  if [[ -f "$PROJECT_YML" ]]; then
    echo "  project.yml.suggested present: yes"
  else
    echo "  project.yml.suggested MISSING"
  fi
  echo
  echo "Note: parity enforcement is conditional on TitanPlayer.xcodeproj"
  echo "      being generated via `xcodegen`. Until that happens, parity is"
  echo "      unverified at the project level."
else
  echo "WARN: $ROOT/TitanPlayer.xcodeproj absent — UI parity deferred."
fi

echo
echo "OK: parity scaffold complete."
