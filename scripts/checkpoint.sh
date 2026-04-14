#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

BUILD_ID="${1:?usage: checkpoint.sh <build-id> <platform> [message]}"
PLATFORM="${2:?usage: checkpoint.sh <build-id> <platform> [message]}"
MESSAGE="${3:-manual checkpoint}"
FILE="$NG_VAR_DIR/checkpoints.jsonl"
mkdir -p "$NG_VAR_DIR"
printf '{"time":"%s","buildId":"%s","platform":"%s","message":"%s"}\n' "$(timestamp)" "$BUILD_ID" "$PLATFORM" "${MESSAGE//\"/\\\"}" >> "$FILE"
cat "$FILE" | tail -1

