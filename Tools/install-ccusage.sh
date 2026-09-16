#!/usr/bin/env bash
# Official ccusage CI build with Antigravity SQLite support. No global install.
set -euo pipefail
cd "$(dirname "$0")/.."
REVISION="d34194988f460fdb9572d138226b9d9380c04a48"
case "${CCUSAGE_ARCH:-$(uname -m)}" in
  arm64) PLATFORM="darwin-arm64"; ARCHIVE_SHA="3d08a5fd602cd3b3f7e0eb887329f60763c94c468abad5d0aaffe0188cb109e4" ;;
  x86_64) PLATFORM="darwin-x64"; ARCHIVE_SHA="e8c17e0a04f704edcc5d24c66687f647d6502fcf7ab57a04f03a7b569b8f03fe" ;;
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
