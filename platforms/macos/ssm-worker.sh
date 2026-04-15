#!/bin/bash
# Long-running macOS WebKit build + artifact sync, started detached from the short SSM bootstrap.
# Args: WORKDIR BUNDLE_ROOT S3_PREFIX
set -euo pipefail
WORKDIR="$1"
BUNDLE_ROOT="$2"
S3_PREFIX="$3"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
export HOME="${HOME:-/var/root}"

LOG="$WORKDIR/worker-output.log"
exec >"$LOG" 2>&1
echo "worker started at $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$"

cleanup() {
  # Guarantee a marker exists
  if [ ! -f "$WORKDIR/BUILD_DONE.txt" ] && [ ! -f "$WORKDIR/BUILD_FAILED.txt" ]; then
    echo "worker exited without markers at $(date -u +%Y-%m-%dT%H:%M:%SZ) - see worker-output.log" \
      > "$WORKDIR/BUILD_FAILED.txt"
  fi
}
trap cleanup EXIT

if "$BUNDLE_ROOT/remote-build.sh"; then
  echo "success $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORKDIR/BUILD_DONE.txt"
  ARTDIR="$WORKDIR/artifacts"
  if [ -d "$ARTDIR" ]; then
    aws s3 sync "$ARTDIR" "$S3_PREFIX" \
      --exclude "*" --include "*.tar.gz" --include "*.json" --include "*.log"
  fi
else
  EXIT_CODE=$?
  echo "remote-build.sh failed with exit $EXIT_CODE at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$WORKDIR/BUILD_FAILED.txt"
  # Upload whatever artifacts exist (partial logs)
  ARTDIR="$WORKDIR/artifacts"
  if [ -d "$ARTDIR" ]; then
    aws s3 sync "$ARTDIR" "$S3_PREFIX" \
      --exclude "*" --include "*.log" --include "*.json" 2>/dev/null || true
  fi
fi
