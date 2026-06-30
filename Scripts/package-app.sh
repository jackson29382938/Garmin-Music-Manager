#!/usr/bin/env bash
#
# Builds GarminMusicManager and assembles a macOS .app bundle in ./dist
#
# Usage:
#   ./Scripts/package-app.sh            # release build (default)
#   ./Scripts/package-app.sh --debug    # debug build
#
set -euo pipefail

APP_NAME="GarminMusicManager"
BUNDLE_ID="com.garminmusicmanager.app"
DISPLAY_NAME="Garmin Music Manager"

# Resolve repo root (parent of this script's directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$DISPLAY_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Derive a version from git (fallback to 0.1.0).
VERSION="$(git describe --tags --always 2>/dev/null || echo "0.1.0")"

echo "==> Building $APP_NAME ($CONFIG)"
swift build -c "$CONFIG"

BINARY_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
    echo "error: built binary not found at $BINARY_PATH" >&2
    exit 1
fi

echo "==> Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>Garmin Music Manager reads your Apple Music library to let you browse playlists and albums and copy local tracks to your watch.</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature so Gatekeeper allows local launch.
if command -v codesign >/dev/null 2>&1; then
    echo "==> Ad-hoc signing"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
        echo "warning: ad-hoc signing failed (app will still run locally)" >&2
fi

echo "==> Done: $APP_DIR (version $VERSION)"
echo "    Launch with: open \"$APP_DIR\""
