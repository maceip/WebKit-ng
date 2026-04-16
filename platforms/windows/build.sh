#!/usr/bin/env bash
# Windows build: clean checkout, repo patches only, manifests (see BUILD_LAW.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/../../scripts/common.sh"
load_env

ID="${1:-$(build_id)}"
REGION="${AWS_REGION:-eu-west-1}"
INSTANCE_ID="${NG_WINDOWS_INSTANCE_ID:-i-05ab9a8ed6d325b3d}"
WORKDIR="${NG_WINDOWS_WORKDIR:-C:/Bootstrap/ng-webkit-$ID}"
S3_PREFIX="${NG_WINDOWS_ARTIFACT_S3:-${NG_ARTIFACT_BUCKET:-s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit}/windows/$ID}"
BOOTSTRAP="${NG_WINDOWS_BOOTSTRAP:-C:/Bootstrap}"
TOOLBIN="${NG_WINDOWS_TOOLBIN:-C:/Bootstrap/toolbin}"
RUBY="${NG_WINDOWS_RUBY:-C:/Ruby34-x64}"
LLVM="${NG_WINDOWS_LLVM:-C:/Program Files/LLVM}"
GIT="${NG_WINDOWS_GIT:-C:/Program Files/Git/cmd}"
CMAKE_BIN="${NG_WINDOWS_CMAKE:-C:/Program Files/CMake/bin}"
NINJA_BIN="${NG_WINDOWS_NINJA:-C:/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja}"
PERL_BIN="${NG_WINDOWS_PERL:-C:/Strawberry/perl/bin}"
VS_DEV_CMD="${NG_WINDOWS_VSDEVCMD:-C:/BuildTools/Common7/Tools/VsDevCmd.bat}"
VCPKG_ROOT="${NG_WINDOWS_VCPKG_ROOT:-C:/vcpkg}"
ENABLE_SCCACHE="${NG_WINDOWS_ENABLE_SCCACHE:-0}"
SCCACHE_EXE="${NG_WINDOWS_SCCACHE_EXE:-$TOOLBIN/sccache.exe}"
SCCACHE_DIR="${NG_WINDOWS_SCCACHE_DIR:-C:/Bootstrap/sccache}"

WEBKIT_URL="${NG_WINDOWS_WEBKIT_URL:-https://github.com/WebKit/WebKit.git}"
WEBKIT_COMMIT="${NG_WINDOWS_WEBKIT_COMMIT:-52dbebe20b922cab89928085f9dcfa8082a813e4}"
if [[ "${NG_WINDOWS_SOURCE_PRESET:-}" == "iangrunert-win-gigacage-skia-fixes" ]]; then
  WEBKIT_URL="${NG_WINDOWS_WEBKIT_URL:-https://github.com/iangrunert/WebKit.git}"
  WEBKIT_COMMIT="${NG_WINDOWS_WEBKIT_COMMIT:-64f58084c78130b874d05dbcfb508147354095af}"
fi
# Short tree path: CMake emits .bat custom commands with huge argv lists; Windows cmd.exe
# limits a single line to ~8191 chars (generate-serializers.py with many .serialization.in paths).
# Default C:/W/n<hash> keeps per-path prefixes small. Override with NG_WINDOWS_CLEAN_SOURCE.
if [[ -z "${NG_WINDOWS_CLEAN_SOURCE+x}" ]]; then
  _wk_short="$(printf '%s' "$ID" | md5sum | awk '{print substr($1,1,14)}')"
  CLEAN_SOURCE="C:/W/n${_wk_short}"
else
  CLEAN_SOURCE="${NG_WINDOWS_CLEAN_SOURCE}"
fi
LEGACY_SOURCE="${NG_WINDOWS_SOURCE:-C:/Work/WebKit}"
USE_CLEAN="${NG_WINDOWS_USE_CLEAN_CHECKOUT:-1}"
if [[ "$USE_CLEAN" == "0" ]]; then
  OUTPUT="${NG_WINDOWS_OUTPUT:-$LEGACY_SOURCE/WebKitBuild/Release}"
else
  OUTPUT="${NG_WINDOWS_OUTPUT:-$CLEAN_SOURCE/WebKitBuild/Release}"
fi

# Baseline Win port (finish compile first). Set NG_WINDOWS_ENABLE_WEBGPU=1 for WebGPU/Dawn CMake flags.
# Override fully with NG_WINDOWS_BUILD_INNER if needed.
_WIN_BASE='perl Tools\Scripts\build-webkit --release --win -DCMAKE_C_COMPILER=C:/Progra~1/LLVM/bin/clang-cl.exe -DCMAKE_CXX_COMPILER=C:/Progra~1/LLVM/bin/clang-cl.exe -DCMAKE_C_FLAGS=-D_CRT_SECURE_NO_WARNINGS -DCMAKE_CXX_FLAGS=-D_CRT_SECURE_NO_WARNINGS'
if [[ "$ENABLE_SCCACHE" == "1" ]]; then
  _WIN_BASE+=" -DCMAKE_C_COMPILER_LAUNCHER=$SCCACHE_EXE -DCMAKE_CXX_COMPILER_LAUNCHER=$SCCACHE_EXE"
fi
if [[ "${NG_WINDOWS_ENABLE_WEBGPU:-0}" == "1" ]]; then
  BUILD_INNER="${NG_WINDOWS_BUILD_INNER:-${_WIN_BASE} --webgpu -DENABLE_EXPERIMENTAL_FEATURES=ON}"
else
  BUILD_INNER="${NG_WINDOWS_BUILD_INNER:-${_WIN_BASE}}"
fi

require_cmd aws
require_cmd python3
"$SCRIPT_DIR/setup-deps.sh" >/dev/null

STAGE="$NG_ARTIFACT_DIR/windows-bundle-$ID"
rm -rf "$STAGE"
mkdir -p "$STAGE/patches/common" "$STAGE/patches/windows"
export NG_STAGE_PATCH_ROOT="$STAGE/patches"
export NG_BUILD_PLATFORM="windows"
export NG_ROOT
python3 <<'PY'
import json
import os
import shutil
from pathlib import Path

root = Path(os.environ["NG_ROOT"])
patch_root = Path(os.environ["NG_STAGE_PATCH_ROOT"])
platform = os.environ["NG_BUILD_PLATFORM"]
changes_file = root / "config" / "changes.json"

with changes_file.open(encoding="utf-8") as f:
    changes = json.load(f).get("activeChanges", [])

for change_index, change in enumerate(changes):
    if not change.get("enabled"):
        continue
    platforms = change.get("platforms") or []
    if platform not in platforms and "all" not in platforms:
        continue
    change_id = change["id"]
    change_dir = root / "changes" / change_id
    if not change_dir.is_dir():
        raise SystemExit(f"Enabled change does not exist: {change_id}")
    for bucket in ("common", platform):
        source_dir = change_dir / "patches" / bucket
        if not source_dir.is_dir():
            continue
        target_dir = patch_root / bucket
        target_dir.mkdir(parents=True, exist_ok=True)
        for patch_index, patch in enumerate(sorted(source_dir.iterdir())):
            if patch.suffix not in (".patch", ".diff"):
                continue
            target = target_dir / f"0000-change-{change_index:02d}-{patch_index:02d}-{change_id}-{patch.name}"
            shutil.copy2(patch, target)
PY
cp -a "$NG_ROOT/patches/common/." "$STAGE/patches/common/" 2>/dev/null || true
cp -a "$NG_ROOT/patches/windows/." "$STAGE/patches/windows/" 2>/dev/null || true
cp "$SCRIPT_DIR/remote-build.ps1" "$STAGE/"
cp "$SCRIPT_DIR/ssm-worker.ps1" "$STAGE/"

CONFIG_JSON="$STAGE/build-config.json"
PATH_PREPEND="${TOOLBIN};${GIT};${RUBY}/bin;${LLVM}/bin;${CMAKE_BIN};${NINJA_BIN};${PERL_BIN}"

export NG_STAGE_CONFIG_OUT="$CONFIG_JSON"
export NG_BUILD_ID="$ID"
export NG_WORKDIR="$WORKDIR"
export NG_WEBKIT_URL="$WEBKIT_URL"
export NG_WEBKIT_COMMIT="$WEBKIT_COMMIT"
export NG_CLEAN_SOURCE="$CLEAN_SOURCE"
export NG_LEGACY_SOURCE="$LEGACY_SOURCE"
export NG_OUTPUT_WIN="$OUTPUT"
export NG_VS_DEV_CMD="$VS_DEV_CMD"
export NG_PATH_PREPEND="$PATH_PREPEND"
export NG_VCPKG_ROOT="$VCPKG_ROOT"
export NG_BUILD_INNER="$BUILD_INNER"
export NG_USE_CLEAN="$USE_CLEAN"
export NG_ENABLE_SCCACHE="$ENABLE_SCCACHE"
export NG_SCCACHE_EXE="$SCCACHE_EXE"
export NG_SCCACHE_DIR="$SCCACHE_DIR"
export NG_TOOLBIN="$TOOLBIN"
export NG_BOOTSTRAP="$BOOTSTRAP"
# Default cone sparse roots (BUILD_LAW.md): overrides WebKit's bundled .git/config.worktree
# sparse pattern (otherwise only repo-root files appear). Export NG_WINDOWS_SPARSE_PATHS to override;
# use `export NG_WINDOWS_SPARSE_PATHS=` for an explicit empty list (full-tree path in remote-build.ps1).
if [[ -z "${NG_WINDOWS_SPARSE_PATHS+x}" ]]; then
  export NG_WINDOWS_SPARSE_PATHS="Source Tools WebKitLibraries Configurations Websites PerformanceTests ManualTests JSTests WebDriverTests"
fi

python3 <<'PY'
import json, os
out = os.environ["NG_STAGE_CONFIG_OUT"]
use_clean = os.environ.get("NG_USE_CLEAN", "1").strip() not in ("0", "false", "False", "")
enable_sccache = os.environ.get("NG_ENABLE_SCCACHE", "0").strip() in ("1", "true", "True", "yes", "on")
sparse_raw = os.environ.get("NG_WINDOWS_SPARSE_PATHS", "").strip()
sparse = sparse_raw.split() if sparse_raw else []
cfg = {
    "buildId": os.environ["NG_BUILD_ID"],
    "workdir": os.environ["NG_WORKDIR"],
    "webkitGitUrl": os.environ["NG_WEBKIT_URL"],
    "webkitCommit": os.environ["NG_WEBKIT_COMMIT"],
    "useCleanCheckout": use_clean,
    "cleanSourceRoot": os.environ["NG_CLEAN_SOURCE"],
    "legacySourceRoot": os.environ["NG_LEGACY_SOURCE"],
    "outputDir": os.environ["NG_OUTPUT_WIN"],
    "vsDevCmdPath": os.environ["NG_VS_DEV_CMD"],
    "pathPrepend": os.environ["NG_PATH_PREPEND"],
    "vcpkgRoot": os.environ["NG_VCPKG_ROOT"],
    "buildCommandLine": os.environ["NG_BUILD_INNER"],
    "bootstrap": os.environ["NG_BOOTSTRAP"],
    "enableSccache": enable_sccache,
    "sccacheExe": os.environ["NG_SCCACHE_EXE"],
    "sccacheDir": os.environ["NG_SCCACHE_DIR"],
    "toolbin": os.environ["NG_TOOLBIN"],
}
if sparse:
    cfg["sparseCheckoutPaths"] = sparse
with open(out, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PY

PATCH_BUNDLE="$NG_ARTIFACT_DIR/windows-patches-$ID.tar.gz"
tar -C "$(dirname "$STAGE")" -czf "$PATCH_BUNDLE" "$(basename "$STAGE")"
PATCH_URI="$("$NG_ROOT/scripts/upload-artifact.sh" "$PATCH_BUNDLE" "$S3_PREFIX/input")"

# Must match upload-artifact.sh / Windows download (same PermanentRedirect issue).
S3_CP_REGION="${NG_ARTIFACT_UPLOAD_REGION:-eu-central-1}"

REMOTE_PS=$(cat <<EOF
\$ErrorActionPreference = "Stop"
\$awsExe = Join-Path \$env:ProgramFiles "Amazon\\AWSCLIV2\\aws.exe"
if (-not (Test-Path \$awsExe)) { \$awsExe = 'C:\\Program Files (x86)\\Amazon\\AWSCLIV2\\aws.exe' }
if (-not (Test-Path \$awsExe)) { throw "AWS CLI not found at \$awsExe - install AWS CLI v2 on the Windows builder." }
\$b = '$WORKDIR'
New-Item -ItemType Directory -Force -Path \$b | Out-Null
Set-Location \$b
& \$awsExe s3 cp "$PATCH_URI" .\\bundle.tar.gz --region $S3_CP_REGION
tar -xzf .\\bundle.tar.gz
\$root = Join-Path \$b '$(basename "$STAGE")'
\$worker = Join-Path \$root "ssm-worker.ps1"
if (-not (Test-Path \$worker)) { throw "ssm-worker.ps1 missing in bundle at \$worker" }
\$s3p = "$S3_PREFIX"
\$q = [char]34
\$argList = "-NoProfile -ExecutionPolicy Bypass -File " + \$q + \$worker + \$q + " -WorkDir " + \$q + \$b + \$q + " -BundleRoot " + \$q + \$root + \$q + " -S3Prefix " + \$q + \$s3p + \$q + " -AwsExe " + \$q + \$awsExe + \$q
\$proc = Start-Process -FilePath powershell.exe -ArgumentList \$argList -WorkingDirectory \$b -PassThru
Start-Sleep -Seconds 3
\$workerState = Get-Process -Id \$proc.Id -ErrorAction SilentlyContinue
if (-not \$workerState) {
  throw "Detached worker exited immediately before creating a durable build process."
}
"worker_pid=\$(\$proc.Id) started=\$((Get-Date).ToUniversalTime().ToString('o'))" | Set-Content -Path (Join-Path \$b "worker-start.log") -Encoding UTF8
Write-Output "BOOTSTRAP_OK worker_pid=\$(\$proc.Id)"
EOF
)

PARAMS_FILE="$NG_ARTIFACT_DIR/ssm-windows-params-$ID.json"
TMPPS="$NG_ARTIFACT_DIR/remote-body-$ID.txt"
printf '%s' "$REMOTE_PS" >"$TMPPS"
export NG_TMPPS_PATH="$TMPPS"
python3 -c "import json,os; p=os.environ['NG_TMPPS_PATH']; print(json.dumps({'commands':[open(p,encoding='utf-8').read()]}))" >"$PARAMS_FILE"
PARAMS_ABS="$(readlink -f "$PARAMS_FILE" 2>/dev/null || realpath "$PARAMS_FILE" 2>/dev/null || echo "$PARAMS_FILE")"

# WebKit release builds can exceed the default 3600s SSM timeout.
COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunPowerShellScript" \
  --comment "ng-webkit windows build $ID" \
  --timeout-seconds 172800 \
  --parameters "file://$PARAMS_ABS" \
  --query 'Command.CommandId' \
  --output text)"

log "Windows SSM bootstrap command: $COMMAND_ID (detached worker; real build polled via BUILD_DONE.txt)"
# Record for polling / failure triage (see scripts/windows-ssm-poll.sh).
{
  echo "WINDOWS_BUILD_ID=$ID"
  echo "WINDOWS_SSM_COMMAND_ID=$COMMAND_ID"
  echo "WINDOWS_SSM_INSTANCE_ID=$INSTANCE_ID"
  echo "AWS_REGION=$REGION"
  echo "WINDOWS_BUILD_POLL_WORKDIR=$WORKDIR"
} >"$NG_ROOT/var/WINDOWS_ACTIVE_BUILD.env"

aws ssm wait command-executed --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"
BOOT_INV="$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json)"
echo "$BOOT_INV"
BOOT_STATUS="$(echo "$BOOT_INV" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Status',''))")"
if [[ "$BOOT_STATUS" != "Success" ]]; then
  log "Bootstrap SSM did not succeed (Status=$BOOT_STATUS); not polling worker."
  "$NG_ROOT/scripts/notify.sh" "ng-webkit Windows bootstrap SSM FAILED build=$ID status=$BOOT_STATUS command=$COMMAND_ID"
  exit 1
fi

# Detached worker can run >1h; SSM agent still caps inline PowerShell ~3600s. Poll markers (ng_windows_ssm_poll_build_markers in common.sh).
export AWS_REGION="$REGION" NG_WINDOWS_INSTANCE_ID="$INSTANCE_ID"
ng_windows_ssm_poll_build_markers "$WORKDIR"

"$NG_ROOT/scripts/checkpoint.sh" "$ID" windows "windows remote build completed (bootstrap $COMMAND_ID, marker poll OK)"
