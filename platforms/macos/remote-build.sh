#!/bin/bash
# ng-webkit macOS clean build driver. Reads build-config.json from the same directory.
# See BUILD_LAW.md — same pattern as platforms/windows/remote-build.ps1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/build-config.json"
[[ -f "$CONFIG" ]] || { echo "build-config.json not found: $CONFIG" >&2; exit 1; }

# Parse config with python (jq may not be installed)
cfg() { python3 -c "import json,sys; print(json.load(open('$CONFIG'))['$1'])"; }

BUILD_ID="$(cfg buildId)"
WORKDIR="$(cfg workdir)"
SOURCE="$(cfg sourceRoot)"
OUTPUT="$(cfg outputDir)"
WEBKIT_URL="$(cfg webkitGitUrl)"
WEBKIT_COMMIT="$(cfg webkitCommit)"
BUILD_CMD="$(cfg buildCommandLine)"
USE_CLEAN="$(cfg useCleanCheckout)"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

# Ensure git safe.directory for root sessions
git config --global --add safe.directory "$SOURCE" 2>/dev/null || true

ARTDIR="$WORKDIR/artifacts"
mkdir -p "$ARTDIR"

# --- Source checkout ---
if [[ "$USE_CLEAN" == "true" || "$USE_CLEAN" == "1" ]]; then
  CLEAN_ROOT="$(cfg cleanSourceRoot)"
  if [[ -d "$CLEAN_ROOT" ]]; then
    rm -rf "$CLEAN_ROOT"
  fi
  mkdir -p "$(dirname "$CLEAN_ROOT")"
  git clone --filter=blob:none "$WEBKIT_URL" "$CLEAN_ROOT"
  cd "$CLEAN_ROOT"
  git fetch origin "$WEBKIT_COMMIT"
  git checkout -f "$WEBKIT_COMMIT"
  HEAD="$(git rev-parse HEAD)"
  [[ "$HEAD" == "$WEBKIT_COMMIT" ]] || { echo "HEAD $HEAD != pinned $WEBKIT_COMMIT" >&2; exit 1; }
  SOURCE="$CLEAN_ROOT"
else
  [[ -d "$SOURCE/.git" ]] || { echo "sourceRoot is not a git clone: $SOURCE" >&2; exit 1; }
  cd "$SOURCE"
  git fetch origin "$WEBKIT_COMMIT"
  git checkout -f "$WEBKIT_COMMIT"
fi

cd "$SOURCE"

# --- Apply patches ---
PATCH_RECORDS="[]"
for pdir in "$HERE/patches/common" "$HERE/patches/macos"; do
  if [[ -d "$pdir" ]]; then
    for p in "$pdir"/*.patch "$pdir"/*.diff; do
      [[ -f "$p" ]] || continue
      echo "Applying $p"
      git apply --whitespace=nowarn "$p"
      SHA="$(shasum -a 256 "$p" | awk '{print $1}')"
      PATCH_RECORDS="$(python3 -c "import json,sys; r=json.loads('$PATCH_RECORDS'); r.append({'name':'$(basename "$p")','sha256':'$SHA'}); print(json.dumps(r))")"
    done
  fi
done

# Reject files check
REJECTS="$(find "$SOURCE" -name '*.rej' 2>/dev/null || true)"
if [[ -n "$REJECTS" ]]; then
  echo "REJECT FILES:" >&2
  echo "$REJECTS" >&2
  exit 1
fi

# --- Pre-build manifest ---
python3 <<PYEOF
import json
pre = {
    "head": "$(git rev-parse HEAD)",
    "expected": "$WEBKIT_COMMIT",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "statusPorcelain": $(git status --porcelain | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().splitlines()))"),
    "patches": $PATCH_RECORDS
}
with open("$WORKDIR/manifest-pre.json", "w") as f:
    json.dump(pre, f, indent=2)
PYEOF

# --- Clean build dir ---
BUILDDIR="$SOURCE/WebKitBuild"
[[ -d "$BUILDDIR" ]] && rm -rf "$BUILDDIR"

# --- Build ---
LOG="$ARTDIR/build-webkit-$BUILD_ID.log"
echo "Starting build: $BUILD_CMD"
eval "$BUILD_CMD" 2>&1 | tee "$LOG"

# --- Post-build verification ---
[[ -d "$OUTPUT" ]] || { echo "Output dir missing: $OUTPUT" >&2; exit 1; }

# Check for key binaries (macOS WebKit produces frameworks)
for fw in JavaScriptCore.framework WebKit.framework; do
  FW_PATH="$OUTPUT/$fw"
  [[ -d "$FW_PATH" ]] || { echo "Missing framework: $FW_PATH" >&2; exit 1; }
done

# MiniBrowser.app check
MINIBROWSER=""
for mb in "$OUTPUT/MiniBrowser.app" "$OUTPUT/../../Debug/MiniBrowser.app" "$OUTPUT/../MiniBrowser.app"; do
  if [[ -d "$mb" ]]; then
    MINIBROWSER="$mb"
    break
  fi
done

# --- Post-build manifest ---
python3 <<PYEOF
import json, hashlib, os
post = {
    "outputDir": "$OUTPUT",
    "miniBrowser": "${MINIBROWSER:-not found}",
    "frameworks": [d for d in os.listdir("$OUTPUT") if d.endswith(".framework")]
}
with open("$WORKDIR/manifest-post.json", "w") as f:
    json.dump(post, f, indent=2)
PYEOF

# --- Archive ---
cp "$WORKDIR/manifest-pre.json" "$ARTDIR/"
cp "$WORKDIR/manifest-post.json" "$ARTDIR/"
TARPATH="$ARTDIR/ng-webkit-macos-$BUILD_ID.tar.gz"
echo "Creating archive..."
tar -czf "$TARPATH" -C "$OUTPUT" .
echo "Archive: $(du -h "$TARPATH" | awk '{print $1}')"
