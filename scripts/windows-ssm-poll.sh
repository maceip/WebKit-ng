#!/usr/bin/env bash
# Wait for the bootstrap SSM command, then poll BUILD_DONE / BUILD_FAILED (same logic as platforms/windows/build.sh).
# Reads var/WINDOWS_ACTIVE_BUILD.env written by the Windows build, or pass env vars.
# Usage: ./scripts/windows-ssm-poll.sh [bootstrap_poll_interval_seconds]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
load_env

INTERVAL="${1:-60}"
ENV_FILE="$ROOT/var/WINDOWS_ACTIVE_BUILD.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a && source "$ENV_FILE" && set +a
fi
: "${WINDOWS_SSM_COMMAND_ID:?Set WINDOWS_SSM_COMMAND_ID or run from a build that wrote $ENV_FILE}"
: "${WINDOWS_SSM_INSTANCE_ID:?Set WINDOWS_SSM_INSTANCE_ID}"
: "${AWS_REGION:=eu-west-1}"

while true; do
  out="$(aws ssm get-command-invocation \
    --command-id "$WINDOWS_SSM_COMMAND_ID" \
    --instance-id "$WINDOWS_SSM_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --output json 2>&1)" || true
  status="$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Status',''))" 2>/dev/null)" || status="unknown"
  code="$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ResponseCode',''))" 2>/dev/null)" || code=""
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) bootstrap SSM status=$status ResponseCode=$code"
  if [[ "$status" != "InProgress" && "$status" != "Pending" && "$status" != "Delayed" ]]; then
    echo "$out"
    if [[ "$status" == "Success" && "$code" == "0" ]]; then
      if [[ -n "${WINDOWS_BUILD_POLL_WORKDIR:-}" ]]; then
        ng_windows_ssm_poll_build_markers "$WINDOWS_BUILD_POLL_WORKDIR"
      fi
      exit 0
    fi
    exit 1
  fi
  sleep "$INTERVAL"
done
