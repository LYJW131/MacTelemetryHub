#!/usr/bin/env bash
# Official ccusage npm release, platform binary only. No global install.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="20.0.21"
case "${CCUSAGE_ARCH:-$(uname -m)}" in
  arm64) PLATFORM="darwin-arm64"; ARCHIVE_SHA="41536db4ed8085561f0143674154ea8b213039aa677bfd584ade59c0a709f071" ;;
  x86_64) PLATFORM="darwin-x64"; ARCHIVE_SHA="7ae409d7c16bc82304e059c1e1dadf3a99625d13c026473465ae2df3705aa336" ;;
  *) echo "Unsupported ccusage architecture" >&2; exit 1 ;;
esac
DEST=".build/ccusage"
if [[ -x "$DEST/ccusage" && -f "$DEST/revision" && "$(cat "$DEST/revision")" == "$VERSION $PLATFORM" ]]; then
  "$DEST/ccusage" antigravity daily --help >/dev/null
  exit 0
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mac-ccusage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
curl --fail --location --connect-timeout 10 --max-time 120 \
  "https://registry.npmjs.org/@ccusage/ccusage-$PLATFORM/-/ccusage-$PLATFORM-$VERSION.tgz" \
  --output "$STAGE/package.tgz"
ACTUAL_SHA="$(shasum -a 256 "$STAGE/package.tgz" | cut -d ' ' -f 1)"
[[ "$ACTUAL_SHA" == "$ARCHIVE_SHA" ]] || { echo "ccusage archive checksum mismatch" >&2; exit 1; }
tar xzf "$STAGE/package.tgz" --strip-components=2 -C "$STAGE" package/bin/ccusage
chmod 755 "$STAGE/ccusage"
"$STAGE/ccusage" antigravity daily --help >/dev/null
mkdir -p "$DEST"
mv "$STAGE/ccusage" "$DEST/ccusage"
printf '%s %s\n' "$VERSION" "$PLATFORM" > "$DEST/revision"
echo "Prepared ccusage $VERSION ($PLATFORM)"
