#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

DERIVED_DATA="${TMPDIR:-/tmp}/mac-telemetry-hub-xcode"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-telemetry-hub-release.XXXXXX")"
OUTPUT_DIR="$STAGING_DIR/build"
INSTALL_DIR="${MAC_TELEMETRY_INSTALL_DIR:-$HOME/Applications}"
DEVELOPMENT_TEAM_ID="${MAC_TELEMETRY_DEVELOPMENT_TEAM:-2VTXNMR2GL}"
trap 'rm -rf "$STAGING_DIR"' EXIT

Tools/generate-icons.sh

xcodebuild \
  -project MacTelemetryHub.xcodeproj \
  -scheme MacTelemetryHub \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  "CONFIGURATION_BUILD_DIR=$OUTPUT_DIR" \
  "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  "CODE_SIGN_IDENTITY=Apple Development" \
  -allowProvisioningUpdates \
  build

APP_BUNDLE="$OUTPUT_DIR/Mac Telemetry Hub.app"
INSTALLED_APP="$INSTALL_DIR/Mac Telemetry Hub.app"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
ditto --norsrc "$APP_BUNDLE" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

echo "Built and installed: $INSTALLED_APP"
