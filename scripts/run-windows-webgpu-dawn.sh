#!/usr/bin/env bash
# Canonical Windows WebGPU/Dawn lane wrapper. Keeps source preset and feature
# flags in one place so we do not have to reconstruct the 36-hour build command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID="${1:-}"

export NG_WINDOWS_SOURCE_PRESET="${NG_WINDOWS_SOURCE_PRESET:-iangrunert-win-gigacage-skia-fixes}"
export NG_WINDOWS_ENABLE_WEBGPU="${NG_WINDOWS_ENABLE_WEBGPU:-1}"
export NG_WINDOWS_ENABLE_SCCACHE="${NG_WINDOWS_ENABLE_SCCACHE:-1}"

if [[ -n "$ID" ]]; then
  exec "$ROOT/scripts/run-build.sh" windows "$ID"
fi

exec "$ROOT/scripts/run-build.sh" windows
