#!/usr/bin/env bash
set -euo pipefail

NG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG_VAR_DIR="${NG_VAR_DIR:-$NG_ROOT/var}"
NG_LOG_DIR="${NG_LOG_DIR:-$NG_VAR_DIR/logs}"
NG_ARTIFACT_DIR="${NG_ARTIFACT_DIR:-$NG_VAR_DIR/artifacts}"
mkdir -p "$NG_LOG_DIR" "$NG_ARTIFACT_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

load_env() {
  if [[ -f "$NG_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$NG_ROOT/.env"
    set +a
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 127
  }
}

build_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$RANDOM"
}

# Generic SSM marker poller: poll BUILD_DONE.txt / BUILD_FAILED.txt on a remote instance.
# Args: workdir instance region document_name [max_seconds] [interval]
# document_name: "AWS-RunPowerShellScript" for Windows, "AWS-RunShellScript" for macOS/Linux.
_ng_ssm_poll_build_markers() {
  local workdir="$1" instance="$2" region="$3" doc_name="$4"
  local max_seconds="${5:-172800}" interval="${6:-90}"
  local params_file params_abs deadline poll_cid inv out first status

  mkdir -p "$NG_ARTIFACT_DIR"
  params_file="$NG_ARTIFACT_DIR/ssm-poll-marker-$(
    printf '%s' "$workdir" | md5sum | awk '{print $1}'
  ).json"

  if [[ "$doc_name" == "AWS-RunPowerShellScript" ]]; then
    WORKDIR="$workdir" python3 <<'PY' >"$params_file"
import json, os
wd = os.environ["WORKDIR"].replace("'", "''")
script = f"""$ErrorActionPreference = 'Continue'
$d = '{wd}'
if (Test-Path (Join-Path $d 'BUILD_DONE.txt')) {{
  Write-Output 'DONE'
  Get-Content (Join-Path $d 'BUILD_DONE.txt') -Raw
}} elseif (Test-Path (Join-Path $d 'BUILD_FAILED.txt')) {{
  Write-Output 'FAIL'
  Get-Content (Join-Path $d 'BUILD_FAILED.txt') -Raw
}} else {{
  Write-Output 'RUNNING'
}}
"""
print(json.dumps({"commands": [script]}))
PY
  else
    WORKDIR="$workdir" python3 <<'PY' >"$params_file"
import json, os
wd = os.environ["WORKDIR"].replace("'", "'\\''")
script = f"""#!/bin/bash
d='{wd}'
if [ -f "$d/BUILD_DONE.txt" ]; then
  echo DONE
  cat "$d/BUILD_DONE.txt"
elif [ -f "$d/BUILD_FAILED.txt" ]; then
  echo FAIL
  cat "$d/BUILD_FAILED.txt"
else
  echo RUNNING
fi
"""
print(json.dumps({"commands": [script]}))
PY
  fi
  params_abs="$(readlink -f "$params_file" 2>/dev/null || realpath "$params_file" 2>/dev/null || echo "$params_file")"

  deadline=$((SECONDS + max_seconds))
  log "Polling build markers under $workdir (max ${max_seconds}s, every ${interval}s)"
  while ((SECONDS < deadline)); do
    sleep "$interval"
    poll_cid="$(aws ssm send-command \
      --region "$region" \
      --instance-ids "$instance" \
      --document-name "$doc_name" \
      --comment "ng-webkit build marker poll" \
      --timeout-seconds 120 \
      --parameters "file://$params_abs" \
      --query 'Command.CommandId' \
      --output text)"
    aws ssm wait command-executed --region "$region" --command-id "$poll_cid" --instance-id "$instance"
    inv="$(aws ssm get-command-invocation --region "$region" --command-id "$poll_cid" --instance-id "$instance" --output json)"
    out="$(echo "$inv" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('StandardOutputContent') or '')")"
    status="$(echo "$inv" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Status') or '')")"
    first="$(echo "$out" | head -n1 | tr -d '\r')"
    log "Marker poll $poll_cid status=$status first=$first"
    case "$first" in
      DONE)
        log "Remote build finished successfully."
        echo "$out"
        return 0
        ;;
      FAIL)
        log "Remote build failed (BUILD_FAILED.txt on builder)."
        echo "$out"
        return 1
        ;;
      RUNNING) ;;
      *)
        log "Unexpected marker poll output."
        echo "$inv"
        return 1
        ;;
    esac
  done
  log "Timed out waiting for BUILD_DONE / BUILD_FAILED after ${max_seconds}s"
  return 1
}

# Windows-specific wrapper (PowerShell)
ng_windows_ssm_poll_build_markers() {
  local workdir="$1"
  local region="${AWS_REGION:-eu-west-1}"
  local instance="${NG_WINDOWS_INSTANCE_ID:-i-0d254760fe07c5e9f}"
  local max_seconds="${WINDOWS_BUILD_POLL_MAX_SECONDS:-172800}"
  local interval="${WINDOWS_BUILD_POLL_INTERVAL:-90}"
  _ng_ssm_poll_build_markers "$workdir" "$instance" "$region" "AWS-RunPowerShellScript" "$max_seconds" "$interval"
}

# macOS-specific wrapper (Shell)
ng_macos_ssm_poll_build_markers() {
  local workdir="$1"
  local region="${AWS_REGION:-eu-central-1}"
  local instance="${NG_MACOS_INSTANCE_ID:-i-092d7452a5deac519}"
  local max_seconds="${MACOS_BUILD_POLL_MAX_SECONDS:-172800}"
  local interval="${MACOS_BUILD_POLL_INTERVAL:-90}"
  _ng_ssm_poll_build_markers "$workdir" "$instance" "$region" "AWS-RunShellScript" "$max_seconds" "$interval"
}

