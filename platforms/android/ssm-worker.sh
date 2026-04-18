#!/usr/bin/env bash
# Long-running Android build + artifact sync, started detached from the short SSM bootstrap.
# Args: WORKDIR BUNDLE_ROOT S3_PREFIX
set -euo pipefail
WORKDIR="$1"
BUNDLE_ROOT="$2"
S3_PREFIX="$3"

LOG="$WORKDIR/worker-output.log"
exec >"$LOG" 2>&1
echo "worker started at $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$"

cleanup() {
  if [[ ! -f "$WORKDIR/BUILD_DONE.txt" && ! -f "$WORKDIR/BUILD_FAILED.txt" ]]; then
    echo "worker exited without markers at $(date -u +%Y-%m-%dT%H:%M:%SZ) - see worker-output.log" \
      >"$WORKDIR/BUILD_FAILED.txt"
  fi
}
trap cleanup EXIT

if bash "$BUNDLE_ROOT/remote-build.sh"; then
  echo "success $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$WORKDIR/BUILD_DONE.txt"
  ARTDIR="$WORKDIR/artifacts"
  if [[ -d "$ARTDIR" ]]; then
    REG="${NG_ARTIFACT_UPLOAD_REGION:-eu-central-1}"
    if [[ -n "$REG" ]]; then
      aws s3 sync "$ARTDIR" "$S3_PREFIX" \
        --region "$REG" \
        --exclude "*" \
        --include "*.apk" --include "*.aar" --include "*.tar.xz" --include "*.json" --include "*.log"
    else
      aws s3 sync "$ARTDIR" "$S3_PREFIX" \
        --exclude "*" \
        --include "*.apk" --include "*.aar" --include "*.tar.xz" --include "*.json" --include "*.log"
    fi
  fi
else
  EXIT_CODE=$?
  echo "remote-build.sh failed with exit $EXIT_CODE at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >"$WORKDIR/BUILD_FAILED.txt"
  ARTDIR="$WORKDIR/artifacts"
  if [[ -d "$ARTDIR" ]]; then
    aws s3 sync "$ARTDIR" "$S3_PREFIX" \
      --region "${NG_ARTIFACT_UPLOAD_REGION:-eu-central-1}" \
      --exclude "*" --include "*.log" --include "*.json" 2>/dev/null || true
  fi
fi
