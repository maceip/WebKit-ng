#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

ID="${1:-$(build_id)}"
SOURCE="${NG_ANDROID_SOURCE:-/home/ubuntu/webkit/wpe-android}"
ARCH="${NG_ANDROID_ARCH:-arm64}"
S3_PREFIX="${NG_ANDROID_ARTIFACT_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/android/$ID}"

require_cmd git
require_cmd aws
require_cmd java

"$SCRIPT_DIR/setup-deps.sh"
"$NG_ROOT/scripts/apply-patches.sh" android "$SOURCE"

export ANDROID_HOME="${ANDROID_HOME:-/home/ubuntu/Android/Sdk}"
pushd "$SOURCE" >/dev/null
./gradlew ":tools:minibrowser:assembleDebug" ":wpeview:assembleDebug" &
BUILD_PID=$!
"$NG_ROOT/scripts/watch-artifacts.sh" "$SOURCE" "$BUILD_PID" "$S3_PREFIX" "*.apk *.aar *.tar.xz" &
WATCH_PID=$!
wait "$BUILD_PID"
wait "$WATCH_PID" || true
popd >/dev/null

"$NG_ROOT/scripts/checkpoint.sh" "$ID" android "android build completed for $ARCH"

