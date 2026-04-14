#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_env

ARTIFACT="${1:?usage: upload-artifact.sh <file> [s3-prefix]}"
S3_PREFIX="${2:-${NG_ARTIFACT_BUCKET:-}}"
[[ -n "$S3_PREFIX" ]] || { echo "Set NG_ARTIFACT_BUCKET or pass an s3:// prefix" >&2; exit 2; }
require_cmd aws

NAME="$(basename "$ARTIFACT")"
DEST="${S3_PREFIX%/}/$NAME"
log "Uploading $ARTIFACT to $DEST"
aws s3 cp "$ARTIFACT" "$DEST"
printf '%s\n' "$DEST"

