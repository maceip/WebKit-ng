#!/usr/bin/env bash
# Install Xcode on EC2 Mac; on xcodes/xip failure runs fallback (copy .xip to ~/xcode.xip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

REGION="${NG_MACOS_REGION:-eu-central-1}"
INSTANCE_ID="${NG_MACOS_INSTANCE_ID:-i-092d7452a5deac519}"
BOOTSTRAP="${NG_MACOS_BOOTSTRAP:-/Users/ec2-user/ng-bootstrap}"
XCODE_VER="${NG_XCODE_VERSION:-}"

require_cmd aws
require_cmd python3

PING="$(aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)"
[[ "$PING" == "Online" ]] || {
  echo "macOS SSM instance $INSTANCE_ID is not online; ping status: $PING" >&2
  exit 3
}

REMOTE_SCRIPT="$(BOOTSTRAP="$BOOTSTRAP" XCODE_VER="$XCODE_VER" NG_REMOTE="$SCRIPT_DIR/install-xcode-remote.sh" python3 <<'PY'
import os, pathlib
t = pathlib.Path(os.environ["NG_REMOTE"]).read_text(encoding="utf-8")
t = t.replace("__BOOTSTRAP__", os.environ["BOOTSTRAP"])
t = t.replace("__XVER__", os.environ.get("XCODE_VER", ""))
print(t, end="")
PY
)"

PARAMS_FILE="$NG_ARTIFACT_DIR/ssm-macos-xcode-params.json"
TMPBODY="$NG_ARTIFACT_DIR/macos-xcode-body.txt"
printf '%s' "$REMOTE_SCRIPT" >"$TMPBODY"
export NG_TMPBODY_PATH="$TMPBODY"
python3 -c "import json,os; p=os.environ['NG_TMPBODY_PATH']; print(json.dumps({'commands':[open(p,encoding='utf-8').read()]}))" >"$PARAMS_FILE"
PARAMS_ABS="$(readlink -f "$PARAMS_FILE" 2>/dev/null || realpath "$PARAMS_FILE" 2>/dev/null || echo "$PARAMS_FILE")"

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "ng-webkit install xcodes/Xcode on EC2 Mac" \
  --parameters "file://$PARAMS_ABS" \
  --query 'Command.CommandId' \
  --output text)"

log "macOS Xcode install SSM command: $COMMAND_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json
