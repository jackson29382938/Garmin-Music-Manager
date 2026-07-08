#!/usr/bin/env bash
#
# Builds GarminMusicManager and assembles a macOS .app bundle in ./dist
#
# Usage:
#   ./Scripts/package-app.sh                 # release, ad-hoc sign
#   ./Scripts/package-app.sh --debug         # debug build
#   CODESIGN_IDENTITY="Developer ID Application: …" ./Scripts/package-app.sh
#   CODESIGN_IDENTITY="…" NOTARIZE=1 \
#     NOTARY_PROFILE="AC_PASSWORD" ./Scripts/package-app.sh
#
# Env:
#   CODESIGN_IDENTITY   Developer ID / Apple Development identity (default: ad-hoc "-")
#   NOTARIZE=1          Run notarytool after signing (requires Developer ID + profile)
#   NOTARY_PROFILE      Keychain profile name for `xcrun notarytool` (required if NOTARIZE=1)
#   BUNDLE_LIBS=0       Skip bundling libmtp/libusb (default: bundle when found)
#
set -euo pipefail

APP_NAME="GarminMusicManager"
HELPER_NAME="GarminMTPHelper"
BUNDLE_ID="com.garminmusicmanager.app"
DISPLAY_NAME="Garmin Music Manager"
TEAM_ENTITLEMENTS=""  # reserved for future hardened-runtime entitlements file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="release"
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --notarize) NOTARIZE=1 ;;
  esac
done

DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$DISPLAY_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Prefer VERSION file (semver), then git tags, then fallback.
VERSION_FILE="$ROOT_DIR/VERSION"
if [[ -f "$VERSION_FILE" ]]; then
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
elif git -C "$ROOT_DIR" describe --tags --exact-match HEAD >/dev/null 2>&1; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match HEAD | sed 's/^v//')"
elif git -C "$ROOT_DIR/.." describe --tags --exact-match HEAD >/dev/null 2>&1; then
  VERSION="$(git -C "$ROOT_DIR/.." describe --tags --exact-match HEAD | sed 's/^v//')"
else
  # Untagged builds: semver from file if present, else git short hash for diagnostics.
  GIT_DESC="$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null \
    || git -C "$ROOT_DIR/.." describe --tags --always 2>/dev/null \
    || echo "")"
  if [[ -n "$GIT_DESC" ]]; then
    VERSION="$GIT_DESC"
  else
    VERSION="0.1.0"
  fi
fi
echo "==> App version: $VERSION"
ICON_SVG="$ROOT_DIR/Resources/AppIcon.svg"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
BUNDLE_LIBS="${BUNDLE_LIBS:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -f "$ICON_SVG" ]]; then
  echo "==> Generating app icon"
  bash "$SCRIPT_DIR/generate-icon.sh"
fi

echo "==> Building $APP_NAME ($CONFIG)"
swift build -c "$CONFIG"

BINARY_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
HELPER_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$HELPER_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "error: built binary not found at $BINARY_PATH" >&2
  exit 1
fi
if [[ ! -f "$HELPER_PATH" ]]; then
  echo "error: built helper not found at $HELPER_PATH" >&2
  exit 1
fi

echo "==> Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$HELPER_PATH" "$MACOS_DIR/$HELPER_NAME"
chmod +x "$MACOS_DIR/$HELPER_NAME"

if [[ -f "$ICON_ICNS" ]]; then
  cp "$ICON_ICNS" "$RESOURCES_DIR/AppIcon.icns"
fi

# --- Bundle libmtp + libusb so the helper runs without Homebrew on target Macs ---
if [[ "$BUNDLE_LIBS" != "0" ]]; then
  resolve_dylib() {
    # $1 = brew formula / short name (libmtp | libusb)
    local name="$1"
    local patterns=()
    case "$name" in
      libmtp) patterns=("libmtp.9.dylib" "libmtp.dylib") ;;
      libusb) patterns=("libusb-1.0.0.dylib" "libusb-1.0.dylib") ;;
      *) patterns=("${name}.dylib") ;;
    esac
    local candidates=(
      "/opt/homebrew/opt/${name}/lib"
      "/usr/local/opt/${name}/lib"
      "/opt/homebrew/lib"
      "/usr/local/lib"
    )
    for dir in "${candidates[@]}"; do
      [[ -d "$dir" ]] || continue
      for pat in "${patterns[@]}"; do
        if [[ -f "$dir/$pat" ]]; then
          echo "$dir/$pat"
          return 0
        fi
      done
    done
    return 1
  }

  bundle_and_relink() {
    local dylib="$1"
    local basen
    basen="$(basename "$dylib")"
    # Prefer the real file (not a versionless symlink) when possible.
    local real
    real="$(python3 -c "import os; print(os.path.realpath('$dylib'))" 2>/dev/null || echo "$dylib")"
    local real_base
    real_base="$(basename "$real")"
    cp "$real" "$FRAMEWORKS_DIR/$real_base"
    chmod 755 "$FRAMEWORKS_DIR/$real_base"
    if [[ "$real_base" != "$basen" ]]; then
      ln -sf "$real_base" "$FRAMEWORKS_DIR/$basen"
    fi
    echo "$FRAMEWORKS_DIR/$real_base"
  }

  if LIBMTP="$(resolve_dylib libmtp)"; then
    echo "==> Bundling $(basename "$LIBMTP")"
    BUNDLED_MTP="$(bundle_and_relink "$LIBMTP")"
    # libusb is a dependency of libmtp
    if LIBUSB="$(resolve_dylib libusb)"; then
      echo "==> Bundling $(basename "$LIBUSB")"
      BUNDLED_USB="$(bundle_and_relink "$LIBUSB")"
      # Fix libmtp's reference to libusb
      OLD_USB="$(otool -L "$BUNDLED_MTP" | awk '/libusb/{print $1; exit}')"
      if [[ -n "${OLD_USB:-}" ]]; then
        install_name_tool -change "$OLD_USB" "@loader_path/$(basename "$BUNDLED_USB")" "$BUNDLED_MTP" 2>/dev/null || true
      fi
      install_name_tool -id "@rpath/$(basename "$BUNDLED_USB")" "$BUNDLED_USB" 2>/dev/null || true
    fi
    install_name_tool -id "@rpath/$(basename "$BUNDLED_MTP")" "$BUNDLED_MTP" 2>/dev/null || true
    # Point helper at bundled dylibs
    OLD_MTP="$(otool -L "$MACOS_DIR/$HELPER_NAME" | awk '/libmtp/{print $1; exit}')"
    if [[ -n "${OLD_MTP:-}" ]]; then
      install_name_tool -change "$OLD_MTP" "@executable_path/../Frameworks/$(basename "$BUNDLED_MTP")" \
        "$MACOS_DIR/$HELPER_NAME"
    fi
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$HELPER_NAME" 2>/dev/null || true
  else
    echo "warning: libmtp dylib not found; helper will need Homebrew libmtp at runtime" >&2
  fi
fi

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>Garmin Music Manager reads your Apple Music library to let you browse playlists and albums and copy local tracks to your watch.</string>
</dict>
</plist>
PLIST

sign_item() {
  local target="$1"
  local identity="$2"
  local extra=()
  if [[ "$identity" != "-" ]]; then
    extra+=(--options runtime --timestamp)
  fi
  codesign --force --sign "$identity" "${extra[@]}" "$target"
}

if command -v codesign >/dev/null 2>&1; then
  IDENTITY="${CODESIGN_IDENTITY:--}"
  if [[ "$IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc signing"
  else
    echo "==> Signing with identity: $IDENTITY"
  fi

  # Sign nested dylibs first, then helper, then app (inside-out).
  if [[ -d "$FRAMEWORKS_DIR" ]]; then
    find "$FRAMEWORKS_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) | while read -r lib; do
      sign_item "$lib" "$IDENTITY" 2>/dev/null || true
    done
  fi
  sign_item "$MACOS_DIR/$HELPER_NAME" "$IDENTITY" 2>/dev/null || true
  codesign --force --deep --sign "$IDENTITY" \
    $([ "$IDENTITY" != "-" ] && echo --options runtime --timestamp) \
    "$APP_DIR" 2>/dev/null \
    || echo "warning: codesign failed (app may still run locally)" >&2

  echo "==> codesign verify"
  codesign --verify --verbose=2 "$APP_DIR" 2>&1 | tail -5 || true
else
  echo "warning: codesign not available" >&2
fi

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" || "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "error: NOTARIZE=1 requires CODESIGN_IDENTITY set to a Developer ID Application identity" >&2
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "error: NOTARIZE=1 requires NOTARY_PROFILE (notarytool keychain profile)" >&2
    echo "  Create one: xcrun notarytool store-credentials AC_PASSWORD --apple-id … --team-id …" >&2
    exit 1
  fi
  ZIP_PATH="$DIST_DIR/${DISPLAY_NAME// /_}-${VERSION}.zip"
  echo "==> Zipping for notarization: $ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  echo "==> Submitting to Apple notary service"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling ticket"
  xcrun stapler staple "$APP_DIR"
  echo "==> Notarization complete"
fi

echo "==> Done: $APP_DIR (version $VERSION)"
echo "    Launch with: open \"$APP_DIR\""
if [[ "${CODESIGN_IDENTITY:-}" == "" || "${CODESIGN_IDENTITY:-}" == "-" ]]; then
  echo "    Tip: set CODESIGN_IDENTITY for Developer ID signing; NOTARIZE=1 for Gatekeeper distribution."
fi
