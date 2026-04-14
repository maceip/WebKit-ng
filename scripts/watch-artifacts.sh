#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

WATCH_DIR="${1:?usage: watch-artifacts.sh <dir> <build-pid> <s3-prefix> [glob]}"
BUILD_PID="${2:?usage: watch-artifacts.sh <dir> <build-pid> <s3-prefix> [glob]}"
S3_PREFIX="${3:?usage: watch-artifacts.sh <dir> <build-pid> <s3-prefix> [glob]}"
GLOB="${4:-*.tar.xz *.zip *.apk *.aar *.exe *.msi *.7z}"
UPLOADED_FILE="$NG_VAR_DIR/uploaded-${BUILD_PID}.txt"
touch "$UPLOADED_FILE"

upload_new() {
  local pattern file
  for pattern in $GLOB; do
    while IFS= read -r -d '' file; do
      grep -Fxq "$file" "$UPLOADED_FILE" && continue
      "$SCRIPT_DIR/upload-artifact.sh" "$file" "$S3_PREFIX" && printf '%s\n' "$file" >> "$UPLOADED_FILE"
    done < <(find "$WATCH_DIR" -type f -name "$pattern" -print0 2>/dev/null)
  done
}

while kill -0 "$BUILD_PID" 2>/dev/null; do
  upload_new || true
  sleep 20
done
upload_new || true

