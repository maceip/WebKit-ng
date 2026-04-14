#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

PLATFORM="${1:?usage: ship-deps.sh <platform>}"
CONFIG="${NG_DEPS_CONFIG:-$NG_ROOT/config/dependencies.json}"
MACHINES="${NG_MACHINES_CONFIG:-$NG_ROOT/config/build-machines.json}"
require_cmd jq
require_cmd aws

machine_type="$(jq -r --arg platform "$PLATFORM" '.machines[$platform].type' "$MACHINES")"
install_root="$(jq -r --arg platform "$PLATFORM" '.platforms[$platform].installRoot // empty' "$CONFIG")"
machine_root="$(jq -r --arg platform "$PLATFORM" '.machines[$platform].dependencyRoot // empty' "$MACHINES")"
target_root="${install_root:-$machine_root}"
[[ -n "$target_root" && "$target_root" != "null" ]] || { echo "No dependency target root for $PLATFORM" >&2; exit 2; }

if [[ "$machine_type" == "local" ]]; then
  mkdir -p "$target_root"
  jq -c --arg platform "$PLATFORM" '.platforms[$platform].items[]?' "$CONFIG" | while read -r item; do
    kind="$(jq -r '.kind' <<<"$item")"
    if [[ "$kind" == "local-file" ]]; then
      path="$(jq -r '.path' <<<"$item")"
      [[ -f "$path" ]] && rsync -a "$path" "$target_root/"
    elif [[ "$kind" == "s3-prefix" ]]; then
      aws s3 sync "$(jq -r '.uri' <<<"$item")" "$target_root/"
    fi
  done
  exit 0
fi

if [[ "$machine_type" == "aws-ssm" ]]; then
  region_env="$(jq -r --arg platform "$PLATFORM" '.machines[$platform].regionEnv // empty' "$MACHINES")"
  instance_env="$(jq -r --arg platform "$PLATFORM" '.machines[$platform].instanceIdEnv // empty' "$MACHINES")"
  default_region="$(jq -r --arg platform "$PLATFORM" '.machines[$platform].defaultRegion' "$MACHINES")"
  default_instance="$(jq -r --arg platform "$PLATFORM" '.machines[$platform].defaultInstanceId' "$MACHINES")"
  region="${!region_env:-$default_region}"
  instance_id="${!instance_env:-$default_instance}"

  commands_file="$(mktemp)"
  {
    if [[ "$PLATFORM" == "windows" ]]; then
      printf 'New-Item -ItemType Directory -Force -Path "%s" | Out-Null\n' "$target_root"
    else
      printf 'mkdir -p "%s"\n' "$target_root"
    fi
    jq -c --arg platform "$PLATFORM" '.platforms[$platform].items[]?' "$CONFIG" | while read -r item; do
      kind="$(jq -r '.kind' <<<"$item")"
      id="$(jq -r '.id' <<<"$item")"
      if [[ "$kind" == "s3-prefix" ]]; then
        uri="$(jq -r '.uri' <<<"$item")"
        printf 'aws s3 sync "%s" "%s/%s"\n' "$uri" "$target_root" "$id"
      elif [[ "$kind" == "local-file" ]]; then
        path="$(jq -r '.path' <<<"$item")"
        bucket="$(jq -r '.artifactBucket' "$CONFIG")/$PLATFORM/$id"
        s3_uri="$("$SCRIPT_DIR/upload-artifact.sh" "$path" "$bucket" | tail -1)"
        printf 'aws s3 cp "%s" "%s/"\n' "$s3_uri" "$target_root"
      fi
    done
  } > "$commands_file"

  document="AWS-RunShellScript"
  [[ "$PLATFORM" == "windows" ]] && document="AWS-RunPowerShellScript"
  command_id="$(aws ssm send-command \
    --region "$region" \
    --instance-ids "$instance_id" \
    --document-name "$document" \
    --comment "ng-webkit ship dependencies for $PLATFORM" \
    --parameters "commands=$(cat "$commands_file")" \
    --query 'Command.CommandId' \
    --output text)"
  rm -f "$commands_file"
  echo "$command_id"
  exit 0
fi

echo "Unsupported machine type for $PLATFORM: $machine_type" >&2
exit 2

