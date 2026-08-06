#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ICON_DIR="App/MacTelemetryHub/Assets.xcassets/AppIcon.appiconset"
MASTER_ICON="Brand/MacTelemetryHubIcon.png"

sips -z 1024 1024 "$MASTER_ICON" --out "$ICON_DIR/AppIcon.png" >/dev/null

sips -z 16 16 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_DIR/AppIcon.png" --out "$ICON_DIR/icon_512x512.png" >/dev/null

echo "Generated macOS app icon set in $ICON_DIR"
