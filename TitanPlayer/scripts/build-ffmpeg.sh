#!/usr/bin/env bash
#
# Build a single universal FFmpeg.xcframework (arm64 + x86_64) for local use
# by TitanPlayer. Output: TitanPlayer/Frameworks/FFmpeg.xcframework
#
# Usage:
#   scripts/build-ffmpeg.sh            # LGPL build (default)
#   scripts/build-ffmpeg.sh --enable-gpl  # include GPL components
#
# The resulting xcframework is consumed by Package.swift as a binary target
# named "FFmpeg" (import FFmpeg). It is NOT checked into the repo.
set -euo pipefail

# ── Pinned source ──────────────────────────────────────────────────────────
FFMPEG_VERSION="7.1"
FFMPEG_SHA256="40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/TitanPlayer/Frameworks"
OUTPUT_XCFRAMEWORK="$FRAMEWORKS_DIR/FFmpeg.xcframework"

# ── Options ─────────────────────────────────────────────────────────────────
ENABLE_GPL=0
for arg in "$@"; do
    case "$arg" in
        --enable-gpl) ENABLE_GPL=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ "$ENABLE_GPL" -eq 1 ]; then
    cat >&2 <<'WARN'

⚠️  GPL components are ENABLED.
    The resulting binary is covered by the GNU GPL (and, with --enable-version3,
    GPLv3). It may NOT be redistributed in a closed-source or App Store build
    without complying with GPL obligations. Use only for internal / permissive
    builds, or stick to the default LGPL build.

WARN
    sleep 2
fi

# ── Scratch space ────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

# ── Download + verify ────────────────────────────────────────────────────────
echo "→ Downloading FFmpeg $FFMPEG_VERSION"
curl -L -o ffmpeg.tar.xz "$FFMPEG_URL"

echo "→ Verifying SHA256"
echo "$FFMPEG_SHA256  ffmpeg.tar.xz" | shasum -a 256 -c || {
    echo "SHA256 mismatch! Aborting." >&2
    exit 1
}

tar xf ffmpeg.tar.xz
SRC_DIR="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"

# ── Headers + module map for the single `FFmpeg` module ──────────────────────
HEADERS_DIR="$WORK_DIR/FFmpegHeaders"
mkdir -p "$HEADERS_DIR"

cat > "$HEADERS_DIR/FFmpeg.h" <<'EOF'
#import <Libavcodec/avcodec.h>
#import <Libavformat/avformat.h>
#import <Libavutil/avutil.h>
#import <Libavutil/opt.h>
#import <Libavutil/pixfmt.h>
#import <Libavutil/frame.h>
#import <Libavutil/buffer.h>
#import <Libavutil/mem.h>
#import <Libavutil/error.h>
#import <Libavutil/rational.h>
#import <Libswscale/swscale.h>
EOF

cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module FFmpeg {
    umbrella header "FFmpeg.h"
    export *
}
EOF

# ── Configure flags ──────────────────────────────────────────────────────────
CONFIGURE_FLAGS=(
    --disable-programs
    --disable-doc
    --disable-network
    --disable-autodetect
    --disable-avdevice
    --enable-cross-compile
    --enable-static
    --disable-shared
    --enable-swscale
    --enable-videotoolbox
    --disable-gpl
)
if [ "$ENABLE_GPL" -eq 1 ]; then
    # Swap --disable-gpl for the GPL flags (in-place array edit).
    for i in "${!CONFIGURE_FLAGS[@]}"; do
        [[ "${CONFIGURE_FLAGS[$i]}" == "--disable-gpl" ]] && CONFIGURE_FLAGS[$i]="--enable-gpl"
    done
    CONFIGURE_FLAGS+=( --enable-version3 )
fi

# ── Per-architecture build ────────────────────────────────────────────────────
ARCHS=( arm64 x86_64 )
for ARCH in "${ARCHS[@]}"; do
    echo "→ Building FFmpeg for $ARCH"
    BUILD_DIR="$WORK_DIR/build-$ARCH"
    mkdir -p "$BUILD_DIR"

    (
        cd "$SRC_DIR"
        ./configure \
            --prefix="$BUILD_DIR" \
            --arch="$ARCH" \
            --target-os=darwin \
            "${CONFIGURE_FLAGS[@]}" 2>&1 | tail -8

        make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -8
        make install 2>&1 | tail -8
    )
done

# Copy the (architecture-independent) public headers so the umbrella import
# resolves inside the xcframework.
echo "→ Staging FFmpeg headers"
cp -R "$WORK_DIR/build-arm64/include/." "$HEADERS_DIR/"

# ── Fat static libraries → single combined libFFmpeg.a ───────────────────────
echo "→ Creating fat static libraries"
FAT_DIR="$WORK_DIR/fat"
mkdir -p "$FAT_DIR"
for LIB in libavcodec libavformat libavutil libswscale; do
    lipo -create \
        "$WORK_DIR/build-arm64/lib/$LIB.a" \
        "$WORK_DIR/build-x86_64/lib/$LIB.a" \
        -output "$FAT_DIR/$LIB.a"
done
libtool -static -o "$FAT_DIR/libFFmpeg.a" "$FAT_DIR"/libav*.a

# ── xcframework ──────────────────────────────────────────────────────────────
echo "→ Creating xcframework"
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$OUTPUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$FAT_DIR/libFFmpeg.a" \
    -headers "$HEADERS_DIR" \
    -output "$OUTPUT_XCFRAMEWORK"

echo "✅ Wrote $OUTPUT_XCFRAMEWORK"
