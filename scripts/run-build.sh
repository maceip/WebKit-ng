#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

PLATFORM="${1:?usage: run-build.sh <platform> [build-id]}"
ID="${2:-$(build_id)}"
LOG="$NG_LOG_DIR/$ID-$PLATFORM.log"

case "$PLATFORM" in
  android|windows|linux|ios|macos) ;;
  *) echo "Unknown platform: $PLATFORM" >&2; exit 2 ;;
esac

log "Starting $PLATFORM build $ID; log: $LOG"
"$NG_ROOT/platforms/$PLATFORM/build.sh" "$ID" 2>&1 | tee "$LOG"

