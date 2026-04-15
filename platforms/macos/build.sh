#!/usr/bin/env bash
# macOS build: bootstrap → detached worker → marker poll (same pattern as Windows).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

ID="${1:-$(build_id)}"
REGION="${NG_MACOS_REGION:-eu-central-1}"
INSTANCE_ID="${NG_MACOS_INSTANCE_ID:-i-092d7452a5deac519}"
SOURCE="${NG_MACOS_SOURCE:-/Users/ec2-user/Work/WebKit}"
WORKDIR="${NG_MACOS_WORKDIR:-/Users/ec2-user/ng-bootstrap/ng-webkit-$ID}"
S3_PREFIX="${NG_MACOS_ARTIFACT_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/macos/$ID}"

WEBKIT_URL="${NG_MACOS_WEBKIT_URL:-https://github.com/WebKit/WebKit.git}"
WEBKIT_COMMIT="${NG_MACOS_WEBKIT_COMMIT:-${NG_WINDOWS_WEBKIT_COMMIT:-52dbebe20b922cab89928085f9dcfa8082a813e4}}"
USE_CLEAN="${NG_MACOS_USE_CLEAN_CHECKOUT:-0}"
CLEAN_SOURCE="${NG_MACOS_CLEAN_SOURCE:-/Users/ec2-user/Work/WebKit-clean-$ID}"
OUTPUT="${NG_MACOS_OUTPUT:-$SOURCE/WebKitBuild/Release}"

# macOS native build command. build-webkit auto-detects Xcode, cmake, ninja.
BUILD_CMD="${NG_MACOS_BUILD_CMD:-Tools/Scripts/build-webkit --release}"

require_cmd aws
require_cmd python3

# --- Stage the bundle ---
STAGE="$NG_ARTIFACT_DIR/macos-bundle-$ID"
rm -rf "$STAGE"
mkdir -p "$STAGE/patches/common" "$STAGE/patches/macos"
cp -a "$NG_ROOT/patches/common/." "$STAGE/patches/common/" 2>/dev/null || true
cp -a "$NG_ROOT/patches/macos/." "$STAGE/patches/macos/" 2>/dev/null || true
cp "$SCRIPT_DIR/remote-build.sh" "$STAGE/"
cp "$SCRIPT_DIR/ssm-worker.sh" "$STAGE/"

# --- Build config ---
CONFIG_JSON="$STAGE/build-config.json"
python3 <<PY
import json, os
cfg = {
    "buildId": "$ID",
    "workdir": "$WORKDIR",
    "webkitGitUrl": "$WEBKIT_URL",
    "webkitCommit": "$WEBKIT_COMMIT",
    "useCleanCheckout": "$USE_CLEAN" in ("1", "true", "True"),
    "cleanSourceRoot": "$CLEAN_SOURCE",
    "sourceRoot": "$SOURCE",
    "outputDir": "$OUTPUT",
    "buildCommandLine": "$BUILD_CMD",
}
with open("$CONFIG_JSON", "w") as f:
    json.dump(cfg, f, indent=2)
PY

PATCH_BUNDLE="$NG_ARTIFACT_DIR/macos-patches-$ID.tar.gz"
tar -C "$(dirname "$STAGE")" -czf "$PATCH_BUNDLE" "$(basename "$STAGE")"
PATCH_URI="$("$NG_ROOT/scripts/upload-artifact.sh" "$PATCH_BUNDLE" "$S3_PREFIX/input")"

# --- SSM bootstrap: download bundle, start detached worker ---
BUNDLE_BASENAME="$(basename "$STAGE")"
read -r -d '' BOOTSTRAP_CMD <<SSMEOF || true
set -euxo pipefail
export HOME=/var/root
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\$PATH
WORKDIR='$WORKDIR'
mkdir -p "\$WORKDIR"
cd "\$WORKDIR"
aws s3 cp "$PATCH_URI" bundle.tar.gz
tar -xzf bundle.tar.gz
BUNDLE_ROOT="\$WORKDIR/$BUNDLE_BASENAME"
chmod +x "\$BUNDLE_ROOT/remote-build.sh" "\$BUNDLE_ROOT/ssm-worker.sh"

# SSM agent kills all child processes on exit; nohup+disown is not enough on macOS.
# Use launchctl submit to register a launchd job that survives SSM session cleanup.
LABEL="ng-webkit-worker-$ID"
launchctl remove "\$LABEL" 2>/dev/null || true
launchctl submit -l "\$LABEL" -- bash "\$BUNDLE_ROOT/ssm-worker.sh" "\$WORKDIR" "\$BUNDLE_ROOT" "$S3_PREFIX"
# launchctl submit starts the job immediately; get its PID
sleep 1
WORKER_PID=\$(launchctl list "\$LABEL" 2>/dev/null | awk '/PID/{print \$NF}' || echo "unknown")
echo "worker_label=\$LABEL worker_pid=\$WORKER_PID started=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "\$WORKDIR/worker-start.log"
echo "BOOTSTRAP_OK worker_label=\$LABEL worker_pid=\$WORKER_PID"
SSMEOF

PARAMS_FILE="$NG_ARTIFACT_DIR/ssm-macos-params-$ID.json"
TMPBODY="$NG_ARTIFACT_DIR/macos-remote-body-$ID.txt"
printf '%s' "$BOOTSTRAP_CMD" >"$TMPBODY"
export NG_TMPBODY_PATH="$TMPBODY"
python3 -c "import json,os; p=os.environ['NG_TMPBODY_PATH']; print(json.dumps({'commands':[open(p,encoding='utf-8').read()]}))" >"$PARAMS_FILE"
PARAMS_ABS="$(readlink -f "$PARAMS_FILE" 2>/dev/null || realpath "$PARAMS_FILE" 2>/dev/null || echo "$PARAMS_FILE")"

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "ng-webkit macOS build $ID" \
  --timeout-seconds 172800 \
  --parameters "file://$PARAMS_ABS" \
  --query 'Command.CommandId' \
  --output text)"

log "macOS SSM bootstrap command: $COMMAND_ID (detached worker; polling BUILD_DONE.txt)"
{
  echo "MACOS_BUILD_ID=$ID"
  echo "MACOS_SSM_COMMAND_ID=$COMMAND_ID"
  echo "MACOS_SSM_INSTANCE_ID=$INSTANCE_ID"
  echo "AWS_REGION=$REGION"
  echo "MACOS_BUILD_POLL_WORKDIR=$WORKDIR"
} >"$NG_ROOT/var/MACOS_ACTIVE_BUILD.env"

aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
BOOT_INV="$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json)"
echo "$BOOT_INV"
BOOT_STATUS="$(echo "$BOOT_INV" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Status',''))")"
if [[ "$BOOT_STATUS" != "Success" ]]; then
  log "Bootstrap SSM did not succeed (Status=$BOOT_STATUS); not polling worker."
  exit 1
fi

# Poll BUILD_DONE / BUILD_FAILED markers (same function as Windows)
export AWS_REGION="$REGION" NG_WINDOWS_INSTANCE_ID="$INSTANCE_ID"
ng_macos_ssm_poll_build_markers "$WORKDIR"

"$NG_ROOT/scripts/checkpoint.sh" "$ID" macos "macOS remote build completed (bootstrap $COMMAND_ID, marker poll OK)"
