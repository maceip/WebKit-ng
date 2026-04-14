#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

PLATFORM="${1:?usage: apply-changes.sh <platform> <source-dir>}"
SOURCE_DIR="${2:?usage: apply-changes.sh <platform> <source-dir>}"
CHANGES_FILE="${NG_CHANGES_FILE:-$NG_ROOT/config/changes.json}"

require_cmd jq
git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null

apply_patch_file() {
  local patch_file="$1"
  log "Applying change patch $(realpath --relative-to "$NG_ROOT" "$patch_file")"
  git -C "$SOURCE_DIR" apply --index "$patch_file" || git -C "$SOURCE_DIR" apply "$patch_file"
}

apply_patch_dir() {
  local patch_dir="$1"
  [[ -d "$patch_dir" ]] || return 0
  find "$patch_dir" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) | sort | while read -r patch_file; do
    apply_patch_file "$patch_file"
  done
}

jq -r --arg platform "$PLATFORM" '
  .activeChanges[]
  | select(.enabled == true)
  | select((.platforms // []) | index($platform) or index("all"))
  | .id
' "$CHANGES_FILE" | while read -r change_id; do
  [[ -n "$change_id" ]] || continue
  change_dir="$NG_ROOT/changes/$change_id"
  [[ -d "$change_dir" ]] || { echo "Enabled change does not exist: $change_id" >&2; exit 4; }
  apply_patch_dir "$change_dir/patches/common"
  apply_patch_dir "$change_dir/patches/$PLATFORM"
done

