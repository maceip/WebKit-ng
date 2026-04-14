#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

ID="${1:-$(build_id)}"
REGION="${AWS_REGION:-eu-west-1}"
INSTANCE_ID="${NG_WINDOWS_INSTANCE_ID:-i-0d254760fe07c5e9f}"
WORKDIR="${NG_WINDOWS_WORKDIR:-C:\\Bootstrap\\ng-webkit}"
S3_PREFIX="${NG_WINDOWS_ARTIFACT_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/windows/$ID}"
SOURCE="${NG_WINDOWS_SOURCE:-C:\\Work\\WebKit}"
OUTPUT="${NG_WINDOWS_OUTPUT:-C:\\Work\\WebKit\\WebKitBuild\\Release}"
BOOTSTRAP="${NG_WINDOWS_BOOTSTRAP:-C:\\Bootstrap}"
TOOLBIN="${NG_WINDOWS_TOOLBIN:-C:\\Bootstrap\\toolbin}"
RUBY="${NG_WINDOWS_RUBY:-C:\\Ruby34-x64}"
LLVM="${NG_WINDOWS_LLVM:-C:\\Program Files\\LLVM}"
GIT="${NG_WINDOWS_GIT:-C:\\Program Files\\Git\\cmd}"
BUILD_COMMAND="${NG_WINDOWS_BUILD_COMMAND:-perl C:\\Work\\WebKit\\Tools\\Scripts\\build-webkit --release --wincairo}"

require_cmd aws
"$SCRIPT_DIR/setup-deps.sh" >/dev/null

PATCH_BUNDLE="$NG_ARTIFACT_DIR/windows-patches-$ID.tar.gz"
tar -C "$NG_ROOT" -czf "$PATCH_BUNDLE" patches/common patches/windows
PATCH_URI="$("$NG_ROOT/scripts/upload-artifact.sh" "$PATCH_BUNDLE" "$S3_PREFIX/input")"

REMOTE_COMMANDS=$(cat <<EOF
\$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "$WORKDIR" | Out-Null
New-Item -ItemType Directory -Force -Path "$WORKDIR\\artifacts" | Out-Null
Set-Location "$WORKDIR"
aws s3 cp "$PATCH_URI" ".\\patches.tar.gz"
tar -xzf ".\\patches.tar.gz"
\$env:NG_BUILD_ID = "$ID"
\$env:NG_PATCH_BUNDLE = "$PATCH_URI"
\$env:NG_ARTIFACT_S3 = "$S3_PREFIX"
\$env:NG_WINDOWS_SOURCE = "$SOURCE"
\$env:PATH = "$TOOLBIN;$GIT;$RUBY\\bin;$LLVM\\bin;" + \$env:PATH
if (Test-Path "$SOURCE\\.git") {
  Set-Location "$SOURCE"
  Get-ChildItem "$WORKDIR\\patches\\common" -Filter *.patch -ErrorAction SilentlyContinue | ForEach-Object { git apply \$_.FullName }
  Get-ChildItem "$WORKDIR\\patches\\common" -Filter *.diff -ErrorAction SilentlyContinue | ForEach-Object { git apply \$_.FullName }
  Get-ChildItem "$WORKDIR\\patches\\windows" -Filter *.patch -ErrorAction SilentlyContinue | ForEach-Object { git apply \$_.FullName }
  Get-ChildItem "$WORKDIR\\patches\\windows" -Filter *.diff -ErrorAction SilentlyContinue | ForEach-Object { git apply \$_.FullName }
}
Set-Location "$BOOTSTRAP"
$BUILD_COMMAND
Set-Location "$WORKDIR"
if (Test-Path "$OUTPUT") {
  Compress-Archive -Path "$OUTPUT\\*" -DestinationPath "$WORKDIR\\artifacts\\ng-webkit-windows-$ID.zip" -Force
}
Copy-Item "$BOOTSTRAP\\*.log" "$WORKDIR\\artifacts" -ErrorAction SilentlyContinue
aws s3 sync "$WORKDIR\\artifacts" "$S3_PREFIX" --exclude "*" --include "*.zip" --include "*.7z" --include "*.exe" --include "*.msi" --include "*.log"
EOF
)

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunPowerShellScript" \
  --comment "ng-webkit windows build $ID" \
  --parameters "commands=$REMOTE_COMMANDS" \
  --query 'Command.CommandId' \
  --output text)"

log "Windows SSM command: $COMMAND_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json
"$NG_ROOT/scripts/checkpoint.sh" "$ID" windows "windows SSM build completed: $COMMAND_ID"
