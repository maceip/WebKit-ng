#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

require_cmd aws
require_cmd python3

REGION="${NG_MACOS_REGION:-eu-central-1}"
INSTANCE_ID="${NG_MACOS_INSTANCE_ID:-i-092d7452a5deac519}"
SOURCE="${NG_MACOS_SOURCE:-/Users/ec2-user/Work/WebKit}"
BOOTSTRAP="${NG_MACOS_BOOTSTRAP:-/Users/ec2-user/ng-bootstrap}"

PING="$(aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)"

[[ "$PING" == "Online" ]] || {
  echo "macOS SSM instance $INSTANCE_ID is not online; ping status: $PING" >&2
  exit 3
}

read -r -d '' REMOTE_SCRIPT <<EOF || true
#!/bin/bash
set -euxo pipefail
export HOME=/var/root
mkdir -p /Users/ec2-user/Work "$BOOTSTRAP"
chown -R ec2-user:staff /Users/ec2-user/Work "$BOOTSTRAP"
sw_vers | tee "$BOOTSTRAP/sw_vers.txt"
uname -a | tee "$BOOTSTRAP/uname.txt"
xcode-select -p | tee "$BOOTSTRAP/xcode-select.txt" || true
xcodebuild -version | tee "$BOOTSTRAP/xcodebuild-version.txt" || true
xcodebuild -license accept 2>/dev/null || true
if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  sudo -u ec2-user env NONINTERACTIVE=1 /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH brew update
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH brew install awscli cmake ninja pkg-config gperf ruby python@3.12 git git-lfs
# Fix git safe.directory for root SSM sessions
git config --global --add safe.directory "$SOURCE"
if [ ! -d "$SOURCE/.git" ]; then
  sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH git clone --filter=blob:none https://github.com/WebKit/WebKit.git "$SOURCE"
fi
EOF

PARAMS_FILE="$NG_ARTIFACT_DIR/ssm-macos-setup-params.json"
TMPBODY="$NG_ARTIFACT_DIR/macos-setup-body.txt"
printf '%s' "$REMOTE_SCRIPT" >"$TMPBODY"
export NG_TMPBODY_PATH="$TMPBODY"
python3 -c "import json,os; p=os.environ['NG_TMPBODY_PATH']; print(json.dumps({'commands':[open(p,encoding='utf-8').read()]}))" >"$PARAMS_FILE"
PARAMS_ABS="$(readlink -f "$PARAMS_FILE" 2>/dev/null || realpath "$PARAMS_FILE" 2>/dev/null || echo "$PARAMS_FILE")"

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "ng-webkit macOS setup deps" \
  --parameters "file://$PARAMS_ABS" \
  --query 'Command.CommandId' \
  --output text)"

echo "$COMMAND_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json
