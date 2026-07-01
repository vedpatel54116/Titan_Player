#!/bin/bash
# Scripts/validate-shaders.sh
# Validates Metal shader files compile without errors.
# Run: bash Scripts/validate-shaders.sh
# Returns non-zero exit code on any shader compilation failure.

set -euo pipefail

SHADER_DIR="${1:-TitanPlayer/Resources/Shaders}"
METAL_BIN="${METAL_BIN:-$(xcrun --sdk macosx --find metal)}"
FAILED=0

echo "Validating Metal shaders in ${SHADER_DIR}..."
echo "Using Metal compiler: ${METAL_BIN}"

for shader in "${SHADER_DIR}"/*.metal; do
    [ -f "$shader" ] || continue
    name=$(basename "$shader")
    echo -n "  ${name}... "
    if "$METAL_BIN" -c "$shader" -o /dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        "$METAL_BIN" -c "$shader" -o /dev/null
        FAILED=1
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "Shader validation FAILED"
    exit 1
fi

echo "All shaders validated successfully"
