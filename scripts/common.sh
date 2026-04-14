#!/usr/bin/env bash
set -euo pipefail

NG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NG_VAR_DIR="${NG_VAR_DIR:-$NG_ROOT/var}"
NG_LOG_DIR="${NG_LOG_DIR:-$NG_VAR_DIR/logs}"
NG_ARTIFACT_DIR="${NG_ARTIFACT_DIR:-$NG_VAR_DIR/artifacts}"
mkdir -p "$NG_LOG_DIR" "$NG_ARTIFACT_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

load_env() {
  if [[ -f "$NG_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$NG_ROOT/.env"
    set +a
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 127
  }
}

build_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$RANDOM"
}

