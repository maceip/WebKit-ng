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
  local params_file params_abs deadline poll_cid inv out first status second third
  local workdir_hash running_polls=0
  workdir_hash="$(printf '%s' "$workdir" | md5sum | awk '{print $1}')"

  mkdir -p "$NG_ARTIFACT_DIR"
  params_file="$NG_ARTIFACT_DIR/ssm-poll-marker-$workdir_hash.json"

  if [[ "$doc_name" == "AWS-RunPowerShellScript" ]]; then
    WORKDIR="$workdir" python3 <<'PY' >"$params_file"
import json, os
wd = os.environ["WORKDIR"].replace("'", "''")
# While RUNNING, scan tails of build-webkit-*.log and worker-output.log. Tool stderr is merged into those streams.
script = """$ErrorActionPreference = 'Continue'
$d = '__WD__'
if (Test-Path (Join-Path $d 'BUILD_DONE.txt')) {
  Write-Output 'DONE'
  Get-Content (Join-Path $d 'BUILD_DONE.txt') -Raw
} elseif (Test-Path (Join-Path $d 'BUILD_FAILED.txt')) {
  Write-Output 'FAIL'
  Get-Content (Join-Path $d 'BUILD_FAILED.txt') -Raw
} else {
  Write-Output 'RUNNING'
  $art = Join-Path $d 'artifacts'
  if (Test-Path $art) { Write-Output 'ARTIFACTS_OK' } else { Write-Output 'ARTIFACTS_MISSING' }
  $compileLine = 'COMPILE_OK'
  $snip = ''
  $parts = New-Object System.Collections.Generic.List[string]
  if (Test-Path $art) {
    $lg = Get-ChildItem $art -Filter 'build-webkit-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $lg) {
      $t = @(Get-Content $lg.FullName -Tail 220 -ErrorAction SilentlyContinue)
      if ($t.Count -gt 0) { [void]$parts.Add(($t -join [char]10)) }
    }
  }
  $wo = Join-Path $d 'worker-output.log'
  if (Test-Path $wo) {
    $w = @(Get-Content $wo -Tail 120 -ErrorAction SilentlyContinue)
    if ($w.Count -gt 0) { [void]$parts.Add(($w -join [char]10)) }
  }
  $text = $parts -join [char]10
  if ($text.Length -gt 0) {
    $errRx = [regex]'(?im)(ninja: build stopped|^FAILED:|\\]:\\s*error:|fatal\\s+error:|^error:|\\berror\\s+C[0-9]{3,5}\\b|CMake Error|LINK\\s*:\\s*fatal|collect2:\\s*error|\\bld:\\s*|git(\\s+|:).*(fatal|error)|patch.*\\bfail|died at|could not find|cannot find|No such file|The system cannot find|not recognized as the name of a cmdlet|Exception:|MSB[0-9]{4}|PR[0-9]{5}|undefined reference|subcommand failed)'
    if ($errRx.IsMatch($text)) {
      $compileLine = 'COMPILE_FAILED'
      $allLines = @()
      if (Test-Path $art) {
        $lg2 = Get-ChildItem $art -Filter 'build-webkit-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $lg2) { $allLines += @(Get-Content $lg2.FullName -Tail 45 -ErrorAction SilentlyContinue) }
      }
      if (Test-Path $wo) { $allLines += '--- worker-output.log (tail) ---'; $allLines += @(Get-Content $wo -Tail 25 -ErrorAction SilentlyContinue) }
      $snip = ($allLines -join [char]10)
    }
  }
  Write-Output $compileLine
  if ($compileLine -eq 'COMPILE_FAILED') { Write-Output $snip }
}
""".replace("__WD__", wd)
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
  if [ -d "$d/artifacts" ]; then echo ARTIFACTS_OK; else echo ARTIFACTS_MISSING; fi
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
    serr="$(echo "$inv" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('StandardErrorContent') or '')")"
    status="$(echo "$inv" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Status') or '')")"
    first="$(echo "$out" | head -n1 | tr -d '\r')"
    second="$(echo "$out" | sed -n '2p' | tr -d '\r')"
    third="$(echo "$out" | sed -n '3p' | tr -d '\r')"
    log "Marker poll $poll_cid status=$status first=$first second=${second:-} third=${third:-}"
    case "$first" in
      DONE)
        log "Remote build finished successfully."
        echo "$out"
        return 0
        ;;
      FAIL)
        log "Remote build failed (BUILD_FAILED.txt on builder)."
        "$NG_ROOT/scripts/notify.sh" \
          "ng-webkit remote build FAILED (BUILD_FAILED.txt) workdir=$workdir poll=$poll_cid" \
          "$(echo "$out" | head -c 4000)"
        echo "$out"
        return 1
        ;;
      RUNNING)
        running_polls=$((running_polls + 1))
        # Tool stderr (git/cmake/ninja/clang/msvc/perl) lands in build-webkit-*.log and worker-output.log — alert with excerpt once.
        if [[ "$doc_name" == "AWS-RunPowerShellScript" && "$third" == "COMPILE_FAILED" ]]; then
          guard="$NG_ARTIFACT_DIR/.ng-alerted-build-stderr-$workdir_hash"
          if [[ ! -f "$guard" ]]; then
            snippet="$(echo "$out" | sed -n '4,$p')"
            "$NG_ROOT/scripts/notify.sh" \
              "ng-webkit Windows: build log / worker log shows FAILURE (stderr patterns) workdir=$workdir poll=$poll_cid" \
              "$(printf '%s\n' "$snippet" | head -c 14000)"
            touch "$guard"
          fi
        fi
        if [[ -n "${serr//[$' \t\r\n']}" && "$doc_name" == "AWS-RunPowerShellScript" ]]; then
          sguard="$NG_ARTIFACT_DIR/.ng-alerted-ssm-stderr-$workdir_hash"
          if [[ ! -f "$sguard" ]]; then
            "$NG_ROOT/scripts/notify.sh" "ng-webkit Windows: SSM command stderr (poll $poll_cid) workdir=$workdir" "$(echo "$serr" | head -c 8000)"
            touch "$sguard"
          fi
        fi
        # Early alarm: worker should create artifacts/ soon after remote-build.ps1 starts. If still missing
        # after N polls, the detached worker likely died (not "still compiling").
        if [[ "${NG_WINDOWS_ALERT_AFTER_POLLS:-0}" != "0" && "${NG_WINDOWS_ALERT_AFTER_POLLS:-0}" -gt 0 && "$doc_name" == "AWS-RunPowerShellScript" ]]; then
          if [[ "$second" == "ARTIFACTS_MISSING" && "$running_polls" -ge "${NG_WINDOWS_ALERT_AFTER_POLLS}" ]]; then
            guard="$NG_ARTIFACT_DIR/.ng-alerted-no-artifacts-$workdir_hash"
            if [[ ! -f "$guard" ]]; then
              "$NG_ROOT/scripts/notify.sh" \
                "ng-webkit Windows: RUNNING but no artifacts/ after ${running_polls} polls (~$((running_polls * interval))s) — worker probably exited before remote-build.ps1 created artifacts. workdir=$workdir instance=$instance"
              touch "$guard"
            fi
          fi
        fi
        ;;
      *)
        log "Unexpected marker poll output."
        "$NG_ROOT/scripts/notify.sh" "ng-webkit marker poll unexpected first line: $first workdir=$workdir" "$(echo "$inv" | head -c 2000)"
        echo "$inv"
        return 1
        ;;
    esac
  done
  log "Timed out waiting for BUILD_DONE / BUILD_FAILED after ${max_seconds}s"
  "$NG_ROOT/scripts/notify.sh" "ng-webkit remote build TIMEOUT after ${max_seconds}s workdir=$workdir instance=$instance"
  return 1
}

# Windows-specific wrapper (PowerShell)
ng_windows_ssm_poll_build_markers() {
  local workdir="$1"
  local region="${AWS_REGION:-eu-west-1}"
  local instance="${NG_WINDOWS_INSTANCE_ID:-i-0d254760fe07c5e9f}"
  local max_seconds="${WINDOWS_BUILD_POLL_MAX_SECONDS:-172800}"
  # Faster default poll so stderr from tools surfaces quickly (SSM latency still applies).
  local interval="${WINDOWS_BUILD_POLL_INTERVAL:-30}"
  # After this many RUNNING polls with no artifacts/, fire notify.sh once (set 0 to disable).
  export NG_WINDOWS_ALERT_AFTER_POLLS="${NG_WINDOWS_ALERT_AFTER_POLLS:-5}"
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

