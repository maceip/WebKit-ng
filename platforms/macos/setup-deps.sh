#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

require_cmd aws

REGION="${NG_MACOS_REGION:-eu-central-1}"
INSTANCE_ID="${NG_MACOS_INSTANCE_ID:-i-092d7452a5deac519}"
SOURCE="${NG_MACOS_SOURCE:-/Users/ec2-user/Work/WebKit}"

PING="$(aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)"

[[ "$PING" == "Online" ]] || {
  echo "macOS SSM instance $INSTANCE_ID is not online; ping status: $PING" >&2
  exit 3
}

read -r -d '' COMMANDS <<EOF || true
set -euxo pipefail
mkdir -p /Users/ec2-user/Work /Users/ec2-user/ng-bootstrap
sw_vers | tee /Users/ec2-user/ng-bootstrap/sw_vers.txt
uname -a | tee /Users/ec2-user/ng-bootstrap/uname.txt
xcode-select -p | tee /Users/ec2-user/ng-bootstrap/xcode-select.txt || true
if [ ! -d "$SOURCE/.git" ]; then
  git clone --filter=blob:none https://github.com/WebKit/WebKit.git "$SOURCE"
fi
cd "$SOURCE"
Tools/Scripts/update-webkit || true
EOF

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "ng-webkit macOS setup deps" \
  --parameters "commands=$COMMANDS" \
  --query 'Command.CommandId' \
  --output text)"

echo "$COMMAND_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json
