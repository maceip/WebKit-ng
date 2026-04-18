#Requires -Version 5.1
# Long-running WebKit build + artifact sync, started detached from the short SSM bootstrap (see build.sh).
param(
  [Parameter(Mandatory = $true)][string]$WorkDir,
  [Parameter(Mandatory = $true)][string]$BundleRoot,
  [Parameter(Mandatory = $true)][string]$S3Prefix,
  [Parameter(Mandatory = $true)][string]$AwsExe
)
$ErrorActionPreference = "Stop"

# Redirect ALL output (stdout+stderr) to a log so we're never blind if the worker dies.
$workerLog = Join-Path $WorkDir "worker-output.log"
Start-Transcript -Path $workerLog -Force -ErrorAction SilentlyContinue

try {
  Set-Location $WorkDir
  # Tar extract is often MOTW-blocked; without Unblock-File, & remote-build.ps1 may not run.
  Get-ChildItem -Path $BundleRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
  Write-Output "worker: Unblock-File done, invoking remote-build.ps1"
  & (Join-Path $BundleRoot "remote-build.ps1")
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "remote-build.ps1 exited with code $LASTEXITCODE"
  }
  "remote-build complete $((Get-Date).ToUniversalTime().ToString('o'))" |
    Set-Content -Path (Join-Path $WorkDir "BUILD_READY.txt") -Encoding UTF8
  $art = Join-Path $WorkDir "artifacts"
  if (Test-Path $art) {
    Write-Output "worker: syncing artifacts to $S3Prefix"
    & $AwsExe s3 sync $art $S3Prefix --exclude "*" --include "*.zip" --include "*.tar.gz" --include "*.json" --include "*.log" --include "*.html"
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
      throw "aws s3 sync exited with code $LASTEXITCODE"
    }
  }
  $done = Join-Path $WorkDir "BUILD_DONE.txt"
  "success $((Get-Date).ToUniversalTime().ToString('o')) uploaded=$S3Prefix" | Set-Content -Path $done -Encoding UTF8
} catch {
  $err = $_ | Out-String
  Write-Output "worker: CAUGHT ERROR: $err"
  $art = Join-Path $WorkDir "artifacts"
  if (Test-Path $art) {
    try {
      Write-Output "worker: syncing failure artifacts to $S3Prefix"
      & $AwsExe s3 sync $art $S3Prefix --exclude "*" --include "*.zip" --include "*.tar.gz" --include "*.json" --include "*.log" --include "*.html"
    } catch {
      Write-Output "worker: failure artifact sync also failed: $($_ | Out-String)"
    }
  }
  try {
    $err | Set-Content (Join-Path $WorkDir "BUILD_FAILED.txt") -Encoding UTF8
  } catch {
    # Last resort: if even writing the marker fails, at least the transcript has the error.
  }
} finally {
  # Guarantee a marker exists: if neither DONE nor FAILED was written, write FAILED with what we know.
  $doneFile = Join-Path $WorkDir "BUILD_DONE.txt"
  $failFile = Join-Path $WorkDir "BUILD_FAILED.txt"
  if (-not (Test-Path $doneFile) -and -not (Test-Path $failFile)) {
    try {
      "worker exited without markers at $((Get-Date).ToUniversalTime().ToString('o')) - see worker-output.log" |
        Set-Content -Path $failFile -Encoding UTF8
    } catch {}
  }
  Stop-Transcript -ErrorAction SilentlyContinue
}
