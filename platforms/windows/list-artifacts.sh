#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

require_cmd aws
BASELINE="${NG_WINDOWS_BASELINE_S3:-s3://cory-build-artifacts-euc1-095713295645-20260407/webkit/windows-build29-20260413}"
aws s3 ls "$BASELINE/" --human-readable --summarize

