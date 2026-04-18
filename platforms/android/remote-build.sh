#!/usr/bin/env bash
# Android Gradle build on the remote Linux builder. Reads build-config.json next to this script.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/build-config.json"
[[ -f "$CONFIG" ]] || { echo "build-config.json not found: $CONFIG" >&2; exit 1; }

cfg() { python3 -c "import json; print(json.load(open('$CONFIG'))['$1'])"; }

BUILD_ID="$(cfg buildId)"
WORKDIR="$(cfg workdir)"
SOURCE="$(cfg sourceRoot)"
REPO="$(cfg androidRepo)"
ARCH="$(cfg arch)"
BUILD_DEPS="$(cfg buildDeps)"
INSTALL_NDK="$(cfg installNdk)"
export ANDROID_HOME="$(cfg androidHome)"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:${PATH:-}"
export NG_ROOT="$HERE/ng"
export NG_CHANGES_FILE="$NG_ROOT/config/changes.json"

ARTDIR="$WORKDIR/artifacts"
mkdir -p "$ARTDIR"
touch "$ARTDIR/.build-start"

log_line() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# --- Source checkout ---
if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p "$(dirname "$SOURCE")"
  git clone "$REPO" "$SOURCE"
fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 127; }; }
require_cmd git
require_cmd python3
require_cmd java
require_cmd jq

cd "$SOURCE"
git fetch --all --tags || true

if [[ "$INSTALL_NDK" == "1" ]]; then
  "$SOURCE/tools/scripts/install-android-ndk.sh"
fi

if [[ "$BUILD_DEPS" == "1" ]]; then
  "$SOURCE/tools/scripts/bootstrap.py" --build --arch="$ARCH" ${NG_ANDROID_DEBUG:+--debug}
else
  "$SOURCE/tools/scripts/bootstrap.py" --arch="$ARCH"
fi

# bootstrap.py may touch local.properties — force sdk.dir for this builder.
printf 'sdk.dir=%s\n' "$ANDROID_HOME" >"$SOURCE/local.properties"

# --- Apply ng patches + enabled changes (same as local apply-patches.sh) ---
chmod +x "$NG_ROOT/scripts/apply-patches.sh" "$NG_ROOT/scripts/apply-changes.sh" "$NG_ROOT/scripts/common.sh" 2>/dev/null || true
bash "$NG_ROOT/scripts/apply-patches.sh" android "$SOURCE"

printf 'sdk.dir=%s\n' "$ANDROID_HOME" >"$SOURCE/local.properties"

# --- Build ---
cd "$SOURCE"
[[ -f ./gradlew ]] && chmod +x ./gradlew
set +e
./gradlew ":tools:minibrowser:assembleDebug" ":wpeview:assembleDebug" 2>&1 | tee "$ARTDIR/gradle-android.log"
GRADLE_EXIT=${PIPESTATUS[0]}
set -e
if [[ "$GRADLE_EXIT" -ne 0 ]]; then
  log_line "gradlew failed with exit $GRADLE_EXIT"
  exit "$GRADLE_EXIT"
fi

# Collect deliverables (same globs as watch-artifacts.sh)
while IFS= read -r -d '' f; do
  cp -a "$f" "$ARTDIR/"
done < <(find "$SOURCE" -type f \( -name '*.apk' -o -name '*.aar' -o -name '*.tar.xz' \) -print0 2>/dev/null)

log_line "remote android build finished buildId=$BUILD_ID"
exit 0
