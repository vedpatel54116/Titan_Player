#!/bin/bash
#
# build-ffmpeg.sh — Convenience wrapper for building FFmpeg via the FFmpegBuild package.
#
# Usage:
#   ./scripts/build-ffmpeg.sh          # Build all platforms
#   ./scripts/build-ffmpeg.sh clean    # Remove build artifacts
#   ./scripts/build-ffmpeg.sh package  # Repackage xcframeworks only
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FFMPEG_BUILD_DIR="${REPO_ROOT}/TitanPlayer/.build/checkouts/FFmpegBuild"

# ── Preflight checks ──────────────────────────────────────

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is required but not found in PATH."
        exit 1
    fi
}

check_tool git
check_tool make
check_tool clang

# ── Resolve FFmpegBuild if not checked out ─────────────────

if [[ ! -d "${FFMPEG_BUILD_DIR}" ]]; then
    echo "→ FFmpegBuild not found at ${FFMPEG_BUILD_DIR}"
    echo "→ Running swift package resolve to fetch dependencies..."
    (cd "${REPO_ROOT}/TitanPlayer" && swift package resolve)
fi

if [[ ! -d "${FFMPEG_BUILD_DIR}" ]]; then
    echo "Error: FFmpegBuild still not found after resolve. Check Package.swift."
    exit 1
fi

# ── Run the actual build ───────────────────────────────────

BUILD_SCRIPT="${FFMPEG_BUILD_DIR}/build.sh"
if [[ ! -f "${BUILD_SCRIPT}" ]]; then
    echo "Error: build.sh not found at ${BUILD_SCRIPT}"
    exit 1
fi

echo "╔══════════════════════════════════════╗"
echo "║  Building FFmpeg via FFmpegBuild     ║"
echo "╚══════════════════════════════════════╝"

"${BUILD_SCRIPT}" "$@"

echo ""
echo "✓ FFmpeg build complete."
echo "  XCFrameworks: ${FFMPEG_BUILD_DIR}/Sources/"
