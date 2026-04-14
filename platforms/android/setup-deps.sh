#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

require_cmd git
require_cmd python3
require_cmd java

export ANDROID_HOME="${ANDROID_HOME:-/home/ubuntu/Android/Sdk}"
SOURCE="${NG_ANDROID_SOURCE:-/home/ubuntu/webkit/wpe-android}"
REPO="${NG_ANDROID_REPO:-https://github.com/Igalia/wpe-android.git}"

if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p "$(dirname "$SOURCE")"
  git clone "$REPO" "$SOURCE"
fi

if [[ "${NG_ANDROID_INSTALL_NDK:-0}" == "1" ]]; then
  "$SOURCE/tools/scripts/install-android-ndk.sh"
fi

if [[ "${NG_ANDROID_BUILD_DEPS:-0}" == "1" ]]; then
  "$SOURCE/tools/scripts/bootstrap.py" --build --arch="${NG_ANDROID_ARCH:-arm64}" ${NG_ANDROID_DEBUG:+--debug}
else
  "$SOURCE/tools/scripts/bootstrap.py" --arch="${NG_ANDROID_ARCH:-arm64}"
fi

