#!/usr/bin/env bash
# scripts/install-app.sh
# Rebuilds the app from scratch and reinstalls it into ~/Applications/TitanPlayer.app

set -euo pipefail

# Print commands as they run
set -x

# 1. Clean and build in release mode
echo "== Cleaning build folder..."
cd TitanPlayer
swift package clean
rm -rf .build

echo "== Building TitanPlayer in release mode..."
swift build -c release

# 2. Setup the application bundle directory
APP_DIR="$HOME/Applications/TitanPlayer.app"
echo "== Recreating App Bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. Copy built executable
echo "== Copying executable..."
cp .build/arm64-apple-macosx/release/TitanPlayer "$APP_DIR/Contents/MacOS/TitanPlayer"

# 4. Copy resources bundle
echo "== Copying resources..."
cp -R .build/arm64-apple-macosx/release/TitanPlayer_TitanPlayer.bundle "$APP_DIR/Contents/Resources/"


# 5. Copy Icon
ICON_SRC="TitanPlayer/Resources/Icon.icns"
if [[ -f "$ICON_SRC" ]]; then
    echo "== Copying Icon.icns..."
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/Icon.icns"
else
    echo "== No Icon.icns found at $ICON_SRC, skipping icon copy..."
fi

# 6. Generate Info.plist
echo "== Generating Info.plist..."
PLIST_DEST="$APP_DIR/Contents/Info.plist"

cat << 'EOF' > "$PLIST_DEST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>TitanPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>com.titanplayer.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TitanPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>NSHumanReadableCopyright</key>
    <string>(c) 2026 Titan Player</string>
    <key>CFBundleIconFile</key>
    <string>Icon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>TitanPlayer uses Apple Events to hand media off to QuickTime or other installed players, and to accept Remote-control commands.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TitanPlayer uses the microphone only when you explicitly enable audio capture. Audio is processed locally and never leaves your Mac.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Media Files</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.audiovisual-content</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.mpeg-4</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# 7. Ad-hoc Sign the App
echo "== Codesigning standard bundle..."
codesign --force --sign - "$APP_DIR"

# 8. Place resource bundle in the root (where Bundle.module expects it)
echo "== Placing resource bundle in the root..."
cp -R .build/arm64-apple-macosx/release/TitanPlayer_TitanPlayer.bundle "$APP_DIR/"

echo "== Installation complete at $APP_DIR =="
