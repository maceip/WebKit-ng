#!/bin/bash
# Executed on EC2 Mac via SSM. Placeholders __BOOTSTRAP__ __XVER__ replaced by install-xcode.sh.
set -euxo pipefail
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH
BOOTSTRAP='__BOOTSTRAP__'
XVER='__XVER__'
mkdir -p "$BOOTSTRAP"
{
  echo "=== disk ==="
  df -h / /System/Volumes/Data 2>/dev/null || df -h
  xcode-select -p 2>&1 || true
  xcodebuild -version 2>&1 || true
} | tee "$BOOTSTRAP/xcode-preflight.txt"

if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  sudo -u ec2-user env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

sudo -u ec2-user mkdir -p /Users/ec2-user/xip-tmp
sudo chmod 700 /Users/ec2-user/xip-tmp

sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH brew update
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH brew install aria2
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH brew install xcodesorg/made/xcodes

sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH xcodes version | tee "$BOOTSTRAP/xcodes-version.txt"
sudo -u ec2-user env PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH xcodes list | tee "$BOOTSTRAP/xcodes-list.txt"

xcode_xip_fallback() {
  sudo -u ec2-user env HOME=/Users/ec2-user TMPDIR=/Users/ec2-user/xip-tmp TMP=/Users/ec2-user/xip-tmp TEMP=/Users/ec2-user/xip-tmp bash <<'INNER'
set -euxo pipefail
mkdir -p "$HOME/xip-tmp" && chmod 700 "$HOME/xip-tmp"
export TMPDIR="$HOME/xip-tmp" TMP="$HOME/xip-tmp" TEMP="$HOME/xip-tmp"
C="$HOME/Library/Application Support/com.robotsandpencils.xcodes"
test -d "$C"
XIP="$(ls -t "$C"/*.xip | head -1)"
cp -f "$XIP" "$HOME/xcode.xip"
/usr/bin/xip --expand "$HOME/xcode.xip"
APP="$(ls -dt /Applications/Xcode*.app | head -1)"
sudo xcode-select -s "$APP/Contents/Developer"
xcodebuild -version
INNER
}

if [ -n "$XVER" ]; then
  if ! sudo -u ec2-user env HOME=/Users/ec2-user TMPDIR=/Users/ec2-user/xip-tmp TMP=/Users/ec2-user/xip-tmp TEMP=/Users/ec2-user/xip-tmp PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH xcodes install "$XVER" --experimental-unxip; then
    echo "xcodes install failed; trying xip copy to \$HOME/xcode.xip (no spaces)..." | tee "$BOOTSTRAP/xcodes-fallback.txt"
    xcode_xip_fallback
  fi
  sudo -u ec2-user env HOME=/Users/ec2-user PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH xcodes select "$XVER" || true
  xcodebuild -version | tee "$BOOTSTRAP/xcodebuild-version-after.txt"
else
  echo "Set NG_XCODE_VERSION and re-run." | tee "$BOOTSTRAP/xcode-next-steps.txt"
fi
