#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

require_cmd aws

REGION="${AWS_REGION:-eu-west-1}"
INSTANCE_ID="${NG_WINDOWS_INSTANCE_ID:-i-05ab9a8ed6d325b3d}"
[[ -n "$INSTANCE_ID" ]] || {
  echo "Set NG_WINDOWS_INSTANCE_ID to the SSM managed Windows builder instance id." >&2
  exit 2
}

PING="$(aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)"

[[ "$PING" == "Online" ]] || {
  echo "Windows SSM instance $INSTANCE_ID is not online; ping status: $PING" >&2
  exit 3
}

echo "$PING"
