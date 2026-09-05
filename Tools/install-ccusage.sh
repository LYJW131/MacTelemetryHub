#!/usr/bin/env bash
# Official ccusage CI build with Antigravity SQLite support. No global install.
set -euo pipefail
cd "$(dirname "$0")/.."
REVISION="51bc8650630de569e5a07f72c65a2e7de8657e11"
case "${CCUSAGE_ARCH:-$(uname -m)}" in
  arm64) PLATFORM="darwin-arm64"; ARCHIVE_SHA="80f8289338f8772283c20a250f7ec445e9a17f945ffca2727ea23e5c5cd00167" ;;
  x86_64) PLATFORM="darwin-x64"; ARCHIVE_SHA="75d8624f6b115ad06647fdbb74f688777cea4be3142c32c6f2c41ffe6a370adb" ;;
  *) echo "Unsupported ccusage architecture" >&2; exit 1 ;;
esac
DEST=".build/ccusage"
if [[ -x "$DEST/ccusage" && -f "$DEST/revision" && "$(cat "$DEST/revision")" == "$REVISION $PLATFORM" ]]; then
  "$DEST/ccusage" antigravity daily --help >/dev/null
  exit 0
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mac-ccusage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
curl --fail --location --connect-timeout 10 --max-time 120 \
  "https://pkg.pr.new/ccusage/ccusage/@ccusage/ccusage-$PLATFORM@$REVISION" \
  --output "$STAGE/package.tgz"
ACTUAL_SHA="$(shasum -a 256 "$STAGE/package.tgz" | cut -d ' ' -f 1)"
[[ "$ACTUAL_SHA" == "$ARCHIVE_SHA" ]] || { echo "ccusage archive checksum mismatch" >&2; exit 1; }
tar xzf "$STAGE/package.tgz" --strip-components=2 -C "$STAGE" package/bin/ccusage
chmod 755 "$STAGE/ccusage"
"$STAGE/ccusage" antigravity daily --help >/dev/null
mkdir -p "$DEST"
mv "$STAGE/ccusage" "$DEST/ccusage"
printf '%s %s\n' "$REVISION" "$PLATFORM" > "$DEST/revision"
echo "Prepared ccusage $REVISION ($PLATFORM)"
