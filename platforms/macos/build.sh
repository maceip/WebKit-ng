#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

ID="${1:-$(build_id)}"
REGION="${NG_MACOS_REGION:-eu-central-1}"
INSTANCE_ID="${NG_MACOS_INSTANCE_ID:-i-092d7452a5deac519}"
SOURCE="${NG_MACOS_SOURCE:-/Users/ec2-user/Work/WebKit}"
OUTPUT="${NG_MACOS_OUTPUT:-/Users/ec2-user/Work/WebKit/WebKitBuild/Release}"
S3_PREFIX="${NG_MACOS_ARTIFACT_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/macos/$ID}"

require_cmd aws
"$SCRIPT_DIR/setup-deps.sh" >/dev/null

PATCH_BUNDLE="$NG_ARTIFACT_DIR/macos-patches-$ID.tar.gz"
tar -C "$NG_ROOT" -czf "$PATCH_BUNDLE" patches/common patches/macos
PATCH_URI="$("$NG_ROOT/scripts/upload-artifact.sh" "$PATCH_BUNDLE" "$S3_PREFIX/input")"

read -r -d '' COMMANDS <<EOF || true
set -euxo pipefail
WORKDIR=/Users/ec2-user/ng-bootstrap/ng-webkit-$ID
mkdir -p "\$WORKDIR/artifacts"
cd "\$WORKDIR"
aws s3 cp "$PATCH_URI" patches.tar.gz
tar -xzf patches.tar.gz
cd "$SOURCE"
find "\$WORKDIR/patches/common" -maxdepth 1 -type f \\( -name '*.patch' -o -name '*.diff' \\) -print0 | sort -z | xargs -0 -n1 git apply
find "\$WORKDIR/patches/macos" -maxdepth 1 -type f \\( -name '*.patch' -o -name '*.diff' \\) -print0 | sort -z | xargs -0 -n1 git apply
Tools/Scripts/build-webkit --release --no-ninja-autoinstall 2>&1 | tee "\$WORKDIR/artifacts/build-webkit-$ID.log"
if [ -d "$OUTPUT" ]; then
  tar -C "$OUTPUT" -cf "\$WORKDIR/artifacts/ng-webkit-macos-$ID-release.tar" .
fi
aws s3 sync "\$WORKDIR/artifacts" "$S3_PREFIX" --exclude '*' --include '*.tar' --include '*.tar.gz' --include '*.zip' --include '*.dmg' --include '*.log'
EOF

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "ng-webkit macOS build $ID" \
  --parameters "commands=$COMMANDS" \
  --query 'Command.CommandId' \
  --output text)"

log "macOS SSM command: $COMMAND_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json
"$NG_ROOT/scripts/checkpoint.sh" "$ID" macos "macOS SSM build completed: $COMMAND_ID"
