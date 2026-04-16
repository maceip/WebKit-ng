#!/usr/bin/env bash
# Provision the Windows SSM builder with the toolchain expected by build.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

usage() {
  cat <<'EOF'
usage: platforms/windows/setup-deps.sh [--no-wait]

Install/provision the dependencies required by the Windows WebKit builder
selected by NG_WINDOWS_INSTANCE_ID. This uploads and runs setup-deps.ps1 on
the Windows host through SSM.

Environment:
  AWS_REGION                         SSM region (default: eu-west-1)
  NG_WINDOWS_INSTANCE_ID             target Windows SSM instance
  NG_WINDOWS_BOOTSTRAP               remote bootstrap root (default: C:/Bootstrap)
  NG_WINDOWS_TOOLBIN                 remote toolbin (default: C:/Bootstrap/toolbin)
  NG_WINDOWS_VCPKG_ROOT              remote vcpkg root (default: C:/vcpkg)
  NG_WINDOWS_PROVISION_S3            S3 prefix for the provision script upload
  NG_WINDOWS_RESTORE_BASELINE_VCPKG  restore release-vcpkg_installed.tar (default: 1)
  NG_WINDOWS_REQUIRE_DAWN            require Dawn header/DLL after setup
  NG_WINDOWS_ENABLE_WEBGPU           also implies NG_WINDOWS_REQUIRE_DAWN=1
  NG_WINDOWS_SETUP_DEPS_ARGS         extra PowerShell args passed through
EOF
}

WAIT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait)
      WAIT=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd aws
require_cmd python3

REGION="${AWS_REGION:-eu-west-1}"
INSTANCE_ID="${NG_WINDOWS_INSTANCE_ID:-i-05ab9a8ed6d325b3d}"
BOOTSTRAP="${NG_WINDOWS_BOOTSTRAP:-C:/Bootstrap}"
TOOLBIN="${NG_WINDOWS_TOOLBIN:-C:/Bootstrap/toolbin}"
VCPKG_ROOT="${NG_WINDOWS_VCPKG_ROOT:-C:/vcpkg}"
PROVISION_S3="${NG_WINDOWS_PROVISION_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/windows/provision}"
S3_CP_REGION="${NG_ARTIFACT_UPLOAD_REGION:-eu-central-1}"
BASELINE_S3="${NG_WINDOWS_BASELINE_S3:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/provision/baseline}"
BASELINE_REGION="${NG_WINDOWS_BASELINE_S3_REGION:-eu-central-1}"
RESTORE_BASELINE="${NG_WINDOWS_RESTORE_BASELINE_VCPKG:-1}"
REQUIRE_DAWN="${NG_WINDOWS_REQUIRE_DAWN:-${NG_WINDOWS_ENABLE_WEBGPU:-0}}"

[[ -n "$INSTANCE_ID" ]] || {
  echo "Set NG_WINDOWS_INSTANCE_ID to the SSM managed Windows builder instance id." >&2
  exit 2
}

PING="$(aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text)"

[[ "$PING" == "Online" ]] || {
  echo "Windows SSM instance $INSTANCE_ID is not online; ping status: $PING" >&2
  exit 3
}

SCRIPT_PATH="$SCRIPT_DIR/setup-deps.ps1"
[[ -f "$SCRIPT_PATH" ]] || {
  echo "Missing Windows provision script: $SCRIPT_PATH" >&2
  exit 4
}

SCRIPT_URI="$("$NG_ROOT/scripts/upload-artifact.sh" "$SCRIPT_PATH" "$PROVISION_S3" | tail -1)"
log "Installing Windows build dependencies on $INSTANCE_ID via $SCRIPT_PATH"

REMOTE_SCRIPT_WIN="${BOOTSTRAP//\//\\}\\setup-deps.ps1"
PS_ARGS=(
  "-Bootstrap" "${BOOTSTRAP//\//\\}"
  "-Toolbin" "${TOOLBIN//\//\\}"
  "-VcpkgRoot" "${VCPKG_ROOT//\//\\}"
  "-BaselineS3Prefix" "$BASELINE_S3"
  "-BaselineS3Region" "$BASELINE_REGION"
)
if [[ "$RESTORE_BASELINE" == "1" || "$RESTORE_BASELINE" == "true" || "$RESTORE_BASELINE" == "yes" ]]; then
  PS_ARGS+=("-RestoreBaselineVcpkg")
fi
if [[ "$REQUIRE_DAWN" == "1" || "$REQUIRE_DAWN" == "true" || "$REQUIRE_DAWN" == "yes" ]]; then
  PS_ARGS+=("-RequireDawn")
fi
if [[ -n "${NG_WINDOWS_SETUP_DEPS_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=(${NG_WINDOWS_SETUP_DEPS_ARGS})
  PS_ARGS+=("${EXTRA_ARGS[@]}")
fi

export NG_REMOTE_SCRIPT_WIN="$REMOTE_SCRIPT_WIN"
export NG_SCRIPT_URI="$SCRIPT_URI"
export NG_S3_CP_REGION="$S3_CP_REGION"
export NG_PS_ARGS_JSON
NG_PS_ARGS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${PS_ARGS[@]}")"

PARAMS_FILE="$NG_ARTIFACT_DIR/windows-setup-deps-params-$(date -u +%Y%m%dT%H%M%SZ).json"
python3 <<'PY' >"$PARAMS_FILE"
import json
import os

remote_script = os.environ["NG_REMOTE_SCRIPT_WIN"]
script_uri = os.environ["NG_SCRIPT_URI"]
region = os.environ["NG_S3_CP_REGION"]
args = json.loads(os.environ["NG_PS_ARGS_JSON"])

def ps_quote(value):
    return "'" + value.replace("'", "''") + "'"

quoted_args = " ".join(ps_quote(a) for a in args)
commands = f"""
$ErrorActionPreference = "Stop"
$awsExe = Join-Path $env:ProgramFiles "Amazon\\AWSCLIV2\\aws.exe"
if (-not (Test-Path $awsExe)) {{ $awsExe = 'C:\\Program Files (x86)\\Amazon\\AWSCLIV2\\aws.exe' }}
if (-not (Test-Path $awsExe)) {{ $awsExe = 'aws.exe' }}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent {ps_quote(remote_script)}) | Out-Null
& $awsExe s3 cp {ps_quote(script_uri)} {ps_quote(remote_script)} --region {ps_quote(region)}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File {ps_quote(remote_script)} {quoted_args}
"""
print(json.dumps({"commands": [commands]}))
PY

COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunPowerShellScript" \
  --comment "ng-webkit windows dependency provisioning" \
  --timeout-seconds 14400 \
  --parameters "file://$PARAMS_FILE" \
  --query 'Command.CommandId' \
  --output text)"

{
  echo "WINDOWS_SETUP_DEPS_COMMAND_ID=$COMMAND_ID"
  echo "WINDOWS_SETUP_DEPS_INSTANCE_ID=$INSTANCE_ID"
  echo "AWS_REGION=$REGION"
  echo "WINDOWS_SETUP_DEPS_SCRIPT=$REMOTE_SCRIPT_WIN"
} >"$NG_ROOT/var/WINDOWS_SETUP_DEPS.env"

echo "Windows setup-deps SSM command: $COMMAND_ID"
if [[ "$WAIT" == "0" ]]; then
  exit 0
fi

aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
INVOCATION="$(aws ssm get-command-invocation \
  --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --output json)"
echo "$INVOCATION"

STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Status",""))' <<<"$INVOCATION")"
if [[ "$STATUS" != "Success" ]]; then
  echo "Windows dependency provisioning failed: $STATUS" >&2
  exit 1
fi
