#!/usr/bin/env bash
#
# Rasterizes Resources/AppIcon.svg into Resources/AppIcon.icns
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SVG_PATH="$ROOT_DIR/Resources/AppIcon.svg"
ICONSET_DIR="$ROOT_DIR/Resources/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/Resources/AppIcon.icns"

if [[ ! -f "$SVG_PATH" ]]; then
    echo "error: missing $SVG_PATH" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

MASTER_PNG="$WORK_DIR/master.png"
qlmanage -t -s 1024 -o "$WORK_DIR" "$SVG_PATH" >/dev/null 2>&1
mv "$WORK_DIR/$(basename "$SVG_PATH").png" "$MASTER_PNG"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    size="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$name" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
echo "Generated $ICNS_PATH"
