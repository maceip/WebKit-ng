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
log "Uploading $ARTIFACT to $DEST" >&2
# Artifact bucket is often eu-central-1 while SSM/default AWS_REGION may be eu-west-1; without
# --region, PutObject can fail with PermanentRedirect. Unset NG_ARTIFACT_UPLOAD_REGION to omit --region.
if [[ -z "${NG_ARTIFACT_UPLOAD_REGION+x}" ]]; then
  NG_ARTIFACT_UPLOAD_REGION=eu-central-1
fi
# aws s3 cp prints progress to stdout — keep stdout clean so callers only capture the URI line below.
if [[ -n "$NG_ARTIFACT_UPLOAD_REGION" ]]; then
  aws s3 cp "$ARTIFACT" "$DEST" --region "$NG_ARTIFACT_UPLOAD_REGION" >/dev/null
else
  aws s3 cp "$ARTIFACT" "$DEST" >/dev/null
fi
printf '%s\n' "$DEST"

