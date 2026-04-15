#!/bin/bash
# Run ON the Mac. xcodes caches .xip under "Application Support/..."; /usr/bin/xip often
# fails on that path — copy to $HOME/xcode.xip first. Always set TMPDIR.
set -euo pipefail
mkdir -p "$HOME/xip-tmp" && chmod 700 "$HOME/xip-tmp"
export TMPDIR="$HOME/xip-tmp" TMP="$HOME/xip-tmp" TEMP="$HOME/xip-tmp"
df -h / /System/Volumes/Data 2>/dev/null || df -h
CACHEDIR="$HOME/Library/Application Support/com.robotsandpencils.xcodes"
shopt -s nullglob
XIPS=("$CACHEDIR"/*.xip)
if [[ ${#XIPS[@]} -eq 0 ]]; then
  echo "No .xip in $CACHEDIR — run xcodes download/install first, or pass .xip path as argv1" >&2
  exit 1
fi
SRC="${1:-}"
[[ -z "$SRC" ]] && SRC="$(ls -t "${XIPS[@]}" | head -1)"
[[ -f "$SRC" ]] || { echo "Not a file: $SRC" >&2; exit 1; }
echo "Expanding: $SRC"
cp -f "$SRC" "$HOME/xcode.xip"
/usr/bin/xip --expand "$HOME/xcode.xip"
APP="$(ls -dt /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
if [[ -n "${APP:-}" ]]; then
  sudo xcode-select -s "$APP/Contents/Developer"
  xcodebuild -version
  xcode-select -p
fi
