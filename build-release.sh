#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

DERIVED_DATA="${TMPDIR:-/tmp}/mac-telemetry-hub-xcode"
OUTPUT_DIR="$PWD/build"

Tools/generate-icons.sh

xcodebuild \
  -project MacTelemetryHub.xcodeproj \
  -scheme MacTelemetryHub \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  "CONFIGURATION_BUILD_DIR=$OUTPUT_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

# Produce a locally runnable bundle even before a paid-team certificate is
# selected in Xcode. For distribution, use Product > Archive in Xcode instead.
APP_BUNDLE="$OUTPUT_DIR/Mac Telemetry Hub.app"
for attempt in 1 2 3; do
  xattr -cr "$APP_BUNDLE"
  xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" 2>/dev/null || true
  if codesign --force --deep --sign - "$APP_BUNDLE" && codesign --verify --deep --strict "$APP_BUNDLE"; then
    break
  fi
  if [[ "$attempt" == 3 ]]; then
    echo "Could not sign the app after clearing FileProvider metadata." >&2
    exit 1
  fi
done

echo "Built: $OUTPUT_DIR/Mac Telemetry Hub.app"
