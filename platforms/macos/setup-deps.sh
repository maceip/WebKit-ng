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
mkdir -p /Users/ec2-user/Work "$BOOTSTRAP"
chown -R ec2-user:staff /Users/ec2-user/Work "$BOOTSTRAP"
sw_vers | tee "$BOOTSTRAP/sw_vers.txt"
uname -a | tee "$BOOTSTRAP/uname.txt"
xcode-select -p | tee "$BOOTSTRAP/xcode-select.txt" || true
xcodebuild -version | tee "$BOOTSTRAP/xcodebuild-version.txt" || true
if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  sudo -u ec2-user env NONINTERACTIVE=1 /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH brew update
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH brew install cmake ninja pkg-config gperf ruby python@3.12 git git-lfs
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/ruby/bin:\$PATH brew --version
if [ ! -d "$SOURCE/.git" ]; then
  sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH git clone --filter=blob:none https://github.com/WebKit/WebKit.git "$SOURCE"
fi
cd "$SOURCE"
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/ruby/bin:\$PATH Tools/Scripts/update-webkit || true
EOF

B64="$(printf '%s' "$REMOTE_SCRIPT" | base64 -w0)"
COMMANDS="echo $B64 | base64 --decode > $BOOTSTRAP/setup-deps.sh && chmod +x $BOOTSTRAP/setup-deps.sh && /bin/bash $BOOTSTRAP/setup-deps.sh"

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
