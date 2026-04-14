#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:?usage: apply-patches.sh <platform> <source-dir>}"
SOURCE_DIR="${2:?usage: apply-patches.sh <platform> <source-dir>}"

apply_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) | sort | while read -r patch_file; do
    echo "Applying $(basename "$patch_file") to $SOURCE_DIR"
    git -C "$SOURCE_DIR" apply --index "$patch_file" || git -C "$SOURCE_DIR" apply "$patch_file"
  done
}

git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null
apply_dir "$ROOT/patches/common"
apply_dir "$ROOT/patches/$PLATFORM"

