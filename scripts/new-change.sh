#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ID="${1:?usage: new-change.sh <change-id> [title]}"
TITLE="${2:-$ID}"
DIR="$NG_ROOT/changes/$ID"

mkdir -p "$DIR/patches"/{common,android,windows,macos,linux,ios}
for platform in common android windows macos linux ios; do
  touch "$DIR/patches/$platform/.gitkeep"
done

cat > "$DIR/manifest.json" <<EOF
{
  "id": "$ID",
  "title": "$TITLE",
  "enabledByDefault": false,
  "description": "",
  "platforms": ["android", "windows", "macos", "linux", "ios"],
  "patchOrder": ["patches/common", "patches/{platform}"]
}
EOF

echo "$DIR"

