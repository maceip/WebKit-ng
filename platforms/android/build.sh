#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

ID="${1:-$(build_id)}"
ARCH="${NG_ANDROID_ARCH:-arm64}"
S3_PREFIX="${NG_ANDROID_ARTIFACT_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/android/$ID}"
SOURCE="${NG_ANDROID_SOURCE:-/home/ubuntu/webkit/wpe-android}"
REPO="${NG_ANDROID_REPO:-https://github.com/Igalia/wpe-android.git}"
ANDROID_HOME_VAL="${ANDROID_HOME:-/home/ubuntu/Android/Sdk}"

REGION="${NG_ANDROID_REGION:-${AWS_REGION:-eu-central-1}}"
WORKDIR="${NG_ANDROID_WORKDIR:-/home/ubuntu/ng-bootstrap/ng-webkit-$ID}"
# Default: remote Linux builder (SSM). Local Gradle only when NG_ANDROID_LOCAL=1 or NG_ANDROID_REMOTE=0.
DEFAULT_REMOTE="${NG_ANDROID_DEFAULT_INSTANCE_ID:-i-08a3afbbac86a0002}"
if [[ "${NG_ANDROID_LOCAL:-0}" == "1" || "${NG_ANDROID_REMOTE:-1}" == "0" ]]; then
  INSTANCE_ID=""
else
  INSTANCE_ID="${NG_ANDROID_INSTANCE_ID:-$DEFAULT_REMOTE}"
fi

# Remote EC2 + SSM (same model as Windows/macOS).
if [[ -n "$INSTANCE_ID" ]]; then
  require_cmd aws
  require_cmd python3
  # Do not inherit the orchestrator laptop's ANDROID_HOME — point at the Linux builder's SDK.
  ANDROID_HOME_VAL="${NG_ANDROID_BUILDER_ANDROID_HOME:-/home/ubuntu/Android/Sdk}"

  STAGE="$NG_ARTIFACT_DIR/android-bundle-$ID"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/ng/scripts" "$STAGE/ng/patches/common" "$STAGE/ng/patches/android" "$STAGE/ng/config"
  cp -a "$NG_ROOT/patches/common/." "$STAGE/ng/patches/common/" 2>/dev/null || true
  cp -a "$NG_ROOT/patches/android/." "$STAGE/ng/patches/android/" 2>/dev/null || true
  cp -a "$NG_ROOT/config/." "$STAGE/ng/config/"
  cp -a "$NG_ROOT/changes" "$STAGE/ng/"
  cp "$NG_ROOT/scripts/apply-patches.sh" "$NG_ROOT/scripts/apply-changes.sh" "$NG_ROOT/scripts/common.sh" "$STAGE/ng/scripts/"
  chmod +x "$STAGE/ng/scripts/"*.sh
  cp "$SCRIPT_DIR/remote-build.sh" "$SCRIPT_DIR/ssm-worker.sh" "$STAGE/"
  chmod +x "$STAGE/remote-build.sh" "$STAGE/ssm-worker.sh"

  CONFIG_JSON="$STAGE/build-config.json"
  python3 <<PY
import json, os
cfg = {
    "buildId": "$ID",
    "workdir": "$WORKDIR",
    "sourceRoot": "$SOURCE",
    "androidRepo": "$REPO",
    "arch": "$ARCH",
    "buildDeps": os.environ.get("NG_ANDROID_BUILD_DEPS", "0"),
    "installNdk": os.environ.get("NG_ANDROID_INSTALL_NDK", "0"),
    "androidHome": "$ANDROID_HOME_VAL",
}
with open("$CONFIG_JSON", "w") as f:
    json.dump(cfg, f, indent=2)
PY

  PATCH_BUNDLE="$NG_ARTIFACT_DIR/android-patches-$ID.tar.gz"
  BUNDLE_BASENAME="$(basename "$STAGE")"
  tar -C "$(dirname "$STAGE")" -czf "$PATCH_BUNDLE" "$BUNDLE_BASENAME"
  PATCH_URI="$("$NG_ROOT/scripts/upload-artifact.sh" "$PATCH_BUNDLE" "$S3_PREFIX/input")"

  BUNDLE_ROOT="$WORKDIR/$BUNDLE_BASENAME"
  WORKER_LOG="${WORKDIR}/worker-output.log"
  read -r -d '' BOOTSTRAP_CMD <<SSMEOF || true
set -eu
mkdir -p $(printf '%q' "$WORKDIR")
chown -R ubuntu:ubuntu $(printf '%q' "$WORKDIR")
sudo -u ubuntu bash -lc "cd $(printf '%q' "$WORKDIR") && aws s3 cp $(printf '%q' "$PATCH_URI") bundle.tar.gz && tar -xzf bundle.tar.gz && chmod +x $(printf '%q' "$BUNDLE_ROOT/remote-build.sh") $(printf '%q' "$BUNDLE_ROOT/ssm-worker.sh")"
sudo -u ubuntu bash -lc "nohup bash $(printf '%q' "$BUNDLE_ROOT/ssm-worker.sh") $(printf '%q' "$WORKDIR") $(printf '%q' "$BUNDLE_ROOT") $(printf '%q' "$S3_PREFIX") >>$(printf '%q' "$WORKER_LOG") 2>&1 &"
echo "BOOTSTRAP_OK android_worker_started=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SSMEOF

  PARAMS_FILE="$NG_ARTIFACT_DIR/ssm-android-params-$ID.json"
  TMPBODY="$NG_ARTIFACT_DIR/android-remote-body-$ID.txt"
  printf '%s' "$BOOTSTRAP_CMD" >"$TMPBODY"
  export NG_TMPBODY_PATH="$TMPBODY"
  python3 -c "import json,os; p=os.environ['NG_TMPBODY_PATH']; print(json.dumps({'commands':[open(p,encoding='utf-8').read()]}))" >"$PARAMS_FILE"
  PARAMS_ABS="$(readlink -f "$PARAMS_FILE" 2>/dev/null || realpath "$PARAMS_FILE" 2>/dev/null || echo "$PARAMS_FILE")"

  COMMAND_ID="$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "ng-webkit Android build $ID" \
    --timeout-seconds 172800 \
    --parameters "file://$PARAMS_ABS" \
    --query 'Command.CommandId' \
    --output text)"

  log "Android SSM bootstrap command: $COMMAND_ID (detached worker; polling BUILD_DONE.txt)"
  {
    echo "ANDROID_BUILD_ID=$ID"
    echo "ANDROID_SSM_COMMAND_ID=$COMMAND_ID"
    echo "ANDROID_SSM_INSTANCE_ID=$INSTANCE_ID"
    echo "AWS_REGION=$REGION"
    echo "ANDROID_BUILD_POLL_WORKDIR=$WORKDIR"
  } >"$NG_ROOT/var/ANDROID_ACTIVE_BUILD.env"

  aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
  BOOT_INV="$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json)"
  echo "$BOOT_INV"
  BOOT_STATUS="$(echo "$BOOT_INV" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Status',''))")"
  if [[ "$BOOT_STATUS" != "Success" ]]; then
    log "Bootstrap SSM did not succeed (Status=$BOOT_STATUS); not polling worker."
    exit 1
  fi

  export AWS_REGION="$REGION" NG_ANDROID_INSTANCE_ID="$INSTANCE_ID"
  ng_android_ssm_poll_build_markers "$WORKDIR"

  "$NG_ROOT/scripts/checkpoint.sh" "$ID" android "Android remote build completed (bootstrap $COMMAND_ID, marker poll OK)"
  exit 0
fi

# --- Local build (NG_ANDROID_LOCAL=1 or NG_ANDROID_REMOTE=0) ---
require_cmd git
require_cmd aws
require_cmd java

"$SCRIPT_DIR/setup-deps.sh"
"$NG_ROOT/scripts/apply-patches.sh" android "$SOURCE"

export ANDROID_HOME="$ANDROID_HOME_VAL"
pushd "$SOURCE" >/dev/null
./gradlew ":tools:minibrowser:assembleDebug" ":wpeview:assembleDebug" &
BUILD_PID=$!
"$NG_ROOT/scripts/watch-artifacts.sh" "$SOURCE" "$BUILD_PID" "$S3_PREFIX" "*.apk *.aar *.tar.xz" &
WATCH_PID=$!
wait "$BUILD_PID"
wait "$WATCH_PID" || true
popd >/dev/null

"$NG_ROOT/scripts/checkpoint.sh" "$ID" android "android build completed for $ARCH"
