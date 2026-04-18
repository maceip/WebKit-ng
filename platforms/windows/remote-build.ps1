#Requires -Version 5.1
<#
  ng-webkit Windows clean/reproducible build driver (see BUILD_LAW.md).
  Expects build-config.json in the same directory as this script.
#>
$ErrorActionPreference = "Stop"

# Git writes progress/info to stderr, which PowerShell treats as a terminating error under
# $ErrorActionPreference = "Stop" (NativeCommandError). Wrap all git calls through this helper.
function Invoke-Git {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & git @args 2>&1
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($output) { $output | ForEach-Object { Write-Host $_ } }
  if ($exitCode -ne 0) {
    throw "git $($args -join ' ') failed with exit code $exitCode"
  }
  return $output
}

function Test-Git {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & git @args 2>&1
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return ($exitCode -eq 0)
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here "build-config.json"
if (-not (Test-Path $configPath)) {
  throw "build-config.json not found: $configPath"
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$patchManifestPath = Join-Path $here "patch-manifest.json"

# Toolchain paths (Git, LLVM, CMake, ...) must be set before any git/perl/cmake call.
if ($config.pathPrepend) {
  $env:PATH = $config.pathPrepend + ";" + $env:PATH
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  foreach ($d in @("C:\Program Files\Git\cmd", "C:\Program Files\Git\bin", "C:\Program Files (x86)\Git\cmd")) {
    $exe = Join-Path $d "git.exe"
    if (Test-Path $exe) {
      $env:PATH = $d + ";" + $env:PATH
      break
    }
  }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git.exe not on PATH after pathPrepend and standard locations - install Git for Windows."
}

New-Item -ItemType Directory -Force -Path $config.workdir | Out-Null
$artDir = Join-Path $config.workdir "artifacts"
New-Item -ItemType Directory -Force -Path $artDir | Out-Null

function Ensure-Sccache {
  if ($null -eq $config.PSObject.Properties["enableSccache"] -or -not [bool]$config.enableSccache) {
    return
  }

  $toolbin = "C:\Bootstrap\toolbin"
  if ($null -ne $config.PSObject.Properties["toolbin"] -and $config.toolbin) {
    $toolbin = $config.toolbin
  }
  New-Item -ItemType Directory -Force -Path $toolbin | Out-Null

  $sccacheExe = Join-Path $toolbin "sccache.exe"
  if ($null -ne $config.PSObject.Properties["sccacheExe"] -and $config.sccacheExe) {
    $sccacheExe = $config.sccacheExe
  }

  if (-not (Test-Path $sccacheExe)) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/mozilla/sccache/releases/latest" -Headers @{ "User-Agent" = "ng-webkit-build" }
    $asset = $release.assets | Where-Object { $_.name -match "x86_64-pc-windows-msvc.*\.zip$" } | Select-Object -First 1
    if (-not $asset) {
      throw "Could not find a Windows sccache asset in the latest mozilla/sccache release."
    }

    $zipPath = Join-Path $config.workdir "sccache.zip"
    $extractPath = Join-Path $config.workdir "sccache"
    if (Test-Path $extractPath) {
      Remove-Item -Recurse -Force $extractPath
    }
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    $downloadedExe = Get-ChildItem -Path $extractPath -Recurse -Filter "sccache.exe" | Select-Object -First 1
    if (-not $downloadedExe) {
      throw "Downloaded sccache archive did not contain sccache.exe."
    }
    Copy-Item $downloadedExe.FullName $sccacheExe -Force
  }

  $cacheDir = "C:\Bootstrap\sccache"
  if ($null -ne $config.PSObject.Properties["sccacheDir"] -and $config.sccacheDir) {
    $cacheDir = $config.sccacheDir
  }
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $env:SCCACHE_DIR = $cacheDir
  $env:SCCACHE_CACHE_SIZE = "50G"
  $env:SCCACHE_IDLE_TIMEOUT = "0"
  & $sccacheExe --start-server | Write-Host
  Write-Host "sccache enabled: $sccacheExe cache=$cacheDir"
}

Ensure-Sccache

function Write-NinjaProgressFromLog {
  param([string]$LogPath, [string]$ProgressPath)
  if (-not (Test-Path $LogPath)) { return }
  $tail = @(Get-Content $LogPath -Tail 8000 -ErrorAction SilentlyContinue)
  if (-not $tail -or $tail.Count -eq 0) { return }
  $text = $tail -join "`n"
  $rx = [regex]'(?m)\[\s*(\d+)\s*/\s*(\d+)\s*\]'
  $mm = $rx.Matches($text)
  if ($mm.Count -eq 0) {
    $early = [ordered]@{
      phase     = "pre-ninja"
      hint      = "Waiting for ninja [n/m] lines (CMake/configure or early build)"
      updated   = (Get-Date).ToUniversalTime().ToString("o")
      buildId   = $config.buildId
    }
    ($early | ConvertTo-Json -Compress) | Set-Content -Path $ProgressPath -Encoding UTF8
    return
  }
  $last = $mm[$mm.Count - 1]
  $done = [int]$last.Groups[1].Value
  $total = [int]$last.Groups[2].Value
  $pct = if ($total -gt 0) { [double][math]::Round(100.0 * $done / $total, 2) } else { 0 }
  $lastLine = ($tail | Where-Object { $_ -match '\[\s*\d+\s*/\s*\d+\s*\]' } | Select-Object -Last 1)
  if (-not $lastLine) { $lastLine = $last.Value }
  $obj = [ordered]@{
    done      = $done
    total     = $total
    percent   = $pct
    lastLine  = $lastLine.Trim()
    backend   = "ninja"
    updated   = (Get-Date).ToUniversalTime().ToString("o")
    buildId   = $config.buildId
  }
  ($obj | ConvertTo-Json -Compress) | Set-Content -Path $ProgressPath -Encoding UTF8
}

function Invoke-BuildCmd {
  param([string]$VsDevCmd, [string]$WorkingDir, [string]$CmdLine)
  # VsDevCmd resets PATH; re-apply toolchain dirs inside the same cmd session (perl, git, ninja, ...).
  # Do NOT put ">> log 2>&1" inside a PowerShell @"@" here-string: ">>" and "2>&1" are parsed as
  # PowerShell redirection, not as cmd.exe syntax, so the build may never run and no log is written.
  $pp = ""
  if ($config.pathPrepend) {
    $pp = $config.pathPrepend + ";"
  }
  $logFile = Join-Path $artDir ("build-webkit-" + $config.buildId + ".log")
  $progressPath = Join-Path $artDir "build-progress.json"
  $batchPath = Join-Path $artDir ("invoke-build-" + $config.buildId + ".cmd")
  $lines = [System.Collections.Generic.List[string]]::new()
  $vcpkgRoot = "C:\vcpkg"
  if ($null -ne $config.PSObject.Properties["vcpkgRoot"] -and $config.vcpkgRoot) {
    $vcpkgRoot = $config.vcpkgRoot
  }
  [void]$lines.Add("@echo off")
  [void]$lines.Add("call `"$VsDevCmd`" -arch=x64 -host_arch=x64")
  [void]$lines.Add("set `"PATH=$pp%PATH%`"")
  [void]$lines.Add("set `"VCPKG_ROOT=$vcpkgRoot`"")
  if ($null -ne $config.PSObject.Properties["enableSccache"] -and [bool]$config.enableSccache) {
    [void]$lines.Add("set `"SCCACHE_DIR=$($config.sccacheDir)`"")
    [void]$lines.Add("set `"SCCACHE_CACHE_SIZE=50G`"")
    [void]$lines.Add("set `"SCCACHE_IDLE_TIMEOUT=0`"")
    [void]$lines.Add("set `"NG_SCCACHE_EXE=$($config.sccacheExe)`"")
    [void]$lines.Add("`"$($config.sccacheExe)`" --zero-stats >> `"$logFile`" 2>&1")
  }
  [void]$lines.Add("cd /d `"$WorkingDir`"")
  [void]$lines.Add("$CmdLine >> `"$logFile`" 2>&1")
  if ($null -ne $config.PSObject.Properties["enableSccache"] -and [bool]$config.enableSccache) {
    [void]$lines.Add("set `"NG_BUILD_EXIT=%ERRORLEVEL%`"")
    [void]$lines.Add("`"$($config.sccacheExe)`" --show-stats >> `"$logFile`" 2>&1")
    [void]$lines.Add("exit /b %NG_BUILD_EXIT%")
  }
  [System.IO.File]::WriteAllLines($batchPath, $lines)
  $pollSec = 15
  $progressJob = Start-Job -ScriptBlock {
    param($LogPath, $ProgressPath, $PollSec, $BuildId)
    $rx = [regex]'(?m)\[\s*(\d+)\s*/\s*(\d+)\s*\]'
    while ($true) {
      try {
        if (Test-Path $LogPath) {
          $tail = @(Get-Content $LogPath -Tail 8000 -ErrorAction SilentlyContinue)
          if ($tail -and $tail.Count -gt 0) {
            $text = $tail -join "`n"
            $mm = $rx.Matches($text)
            if ($mm.Count -gt 0) {
              $last = $mm[$mm.Count - 1]
              $done = [int]$last.Groups[1].Value
              $total = [int]$last.Groups[2].Value
              $pct = if ($total -gt 0) { [double][math]::Round(100.0 * $done / $total, 2) } else { 0 }
              $lastLine = ($tail | Where-Object { $_ -match '\[\s*\d+\s*/\s*\d+\s*\]' } | Select-Object -Last 1)
              if (-not $lastLine) { $lastLine = $last.Value }
              $obj = [ordered]@{
                done      = $done
                total     = $total
                percent   = $pct
                lastLine  = $lastLine.Trim()
                backend   = "ninja"
                updated   = (Get-Date).ToUniversalTime().ToString("o")
                buildId   = $BuildId
              }
              ($obj | ConvertTo-Json -Compress) | Set-Content -Path $ProgressPath -Encoding UTF8
            } else {
              $early = [ordered]@{
                phase     = "pre-ninja"
                hint      = "Waiting for ninja [n/m] lines (CMake/configure or early build)"
                updated   = (Get-Date).ToUniversalTime().ToString("o")
                buildId   = $BuildId
              }
              ($early | ConvertTo-Json -Compress) | Set-Content -Path $ProgressPath -Encoding UTF8
            }
          }
        }
      } catch { }
      Start-Sleep -Seconds $PollSec
    }
  } -ArgumentList $logFile, $progressPath, $pollSec, $config.buildId
  try {
    # Do NOT use Start-Process -NoNewWindow -Wait: PowerShell 5.1 hangs indefinitely
    # in headless SYSTEM sessions even after cmd.exe exits. Use -PassThru + WaitForExit() instead.
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $batchPath) -PassThru
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
      throw "Build command failed with exit $($p.ExitCode) - see $logFile"
    }
  } finally {
    Stop-Job -Job $progressJob -ErrorAction SilentlyContinue
    Remove-Job -Job $progressJob -Force -ErrorAction SilentlyContinue
    Write-NinjaProgressFromLog -LogPath $logFile -ProgressPath $progressPath
  }
}

function Enable-SymlinkEvaluation {
  Write-Host "Ensuring Windows symlink evaluation is enabled for WebKit generated headers"
  $cmd = "fsutil behavior set SymlinkEvaluation L2L:1 L2R:1 R2L:1 R2R:1"
  $setOutput = & cmd.exe /c $cmd 2>&1
  $setOutput | ForEach-Object { Write-Host $_ }
  $queryOutput = & cmd.exe /c "fsutil behavior query SymlinkEvaluation" 2>&1
  $queryOutput | ForEach-Object { Write-Host $_ }
}

$patchRoot = Join-Path $here "patches"
$commonPatches = @(Get-ChildItem (Join-Path $patchRoot "common") -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name)
$winPatches = @(Get-ChildItem (Join-Path $patchRoot "windows") -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name)

$source = $null
if ($config.useCleanCheckout -eq $true) {
  $cleanRoot = $config.cleanSourceRoot
  $reuseCheckout = $false
  if ($null -ne $config.PSObject.Properties["reuseCheckout"]) {
    $reuseCheckout = [bool]$config.reuseCheckout
  }
  if ((Test-Path $cleanRoot) -and -not $reuseCheckout) {
    Remove-Item -Recurse -Force $cleanRoot
  }
  New-Item -ItemType Directory -Force -Path (Split-Path $cleanRoot) | Out-Null
  Invoke-Git config --global core.longpaths true

  $commit = $config.webkitCommit
  $sparse = @($config.sparseCheckoutPaths)
  if ((Test-Path (Join-Path $cleanRoot ".git")) -and $reuseCheckout) {
    Write-Host "Reusing existing checkout: $cleanRoot"
    Set-Location $cleanRoot
    Invoke-Git fetch origin $commit
    Invoke-Git reset --hard $commit
    Invoke-Git clean -fdx -e WebKitBuild/
    $source = $cleanRoot
  } elseif ($sparse.Count -gt 0) {
    Invoke-Git clone --filter=blob:none --no-checkout $config.webkitGitUrl $cleanRoot
    Set-Location $cleanRoot
    Invoke-Git sparse-checkout init --cone
    Invoke-Git sparse-checkout set @sparse
    Invoke-Git fetch origin $commit
    Invoke-Git checkout -f $commit
  } else {
    Invoke-Git clone --filter=blob:none $config.webkitGitUrl $cleanRoot
    Set-Location $cleanRoot
    Invoke-Git fetch origin $commit
    Invoke-Git checkout -f $commit
    # Upstream WebKit sets sparseCheckout in .git/config.worktree so the default cone pattern
    # materializes only repo-root files (no Tools/, Source/, ...). Turn it off for a full tree.
    Invoke-Git sparse-checkout disable
    Invoke-Git reset --hard $commit
  }

  $head = (Invoke-Git rev-parse HEAD | Select-Object -Last 1).ToString().Trim()
  if ($head -ne $commit) {
    throw "HEAD $head does not match pinned commit $commit"
  }
  $source = $cleanRoot
} else {
  $source = $config.legacySourceRoot
  if (-not (Test-Path (Join-Path $source ".git"))) {
    throw "legacySourceRoot is not a git clone: $source"
  }
  Invoke-Git config --global core.longpaths true
  Set-Location $source
}

Set-Location $source

$patchRecords = @()
foreach ($p in ($commonPatches + $winPatches)) {
  Write-Host "Applying $($p.FullName)"
  $wgslCMake = Join-Path $source "Source\WebGPU\WGSL\CMakeLists.txt"
  if ($p.Name -eq "0005-windows-wgsl-generator-three-args.patch" -and (Test-Path $wgslCMake) -and (Select-String -Path $wgslCMake -Pattern "TypeOverloads.h" -Quiet)) {
    Write-Host "Skipping $($p.Name); WGSL generator already emits TypeOverloads.h"
  } elseif (Test-Git apply --check --reverse $p.FullName) {
    Write-Host "Skipping already-applied patch $($p.Name)"
  } else {
    Invoke-Git apply --whitespace=nowarn $p.FullName
  }
  $h = Get-FileHash $p.FullName -Algorithm SHA256
  $patchRecords += @{ name = $p.Name; sha256 = $h.Hash }
}

$rej = @(Get-ChildItem -Path $source -Recurse -Filter *.rej -ErrorAction SilentlyContinue)
if ($rej.Count -gt 0) {
  $rej | ForEach-Object { Write-Host "REJ: $($_.FullName)" }
  throw "git apply produced .rej files; fix patches and retry."
}

$pre = [ordered]@{
  head = (Invoke-Git rev-parse HEAD | Select-Object -Last 1).ToString().Trim()
  expected = $config.webkitCommit
  timestamp = (Get-Date).ToUniversalTime().ToString("o")
  statusPorcelain = @(Invoke-Git status --porcelain)
  patches = $patchRecords
}
$prePath = Join-Path $config.workdir "manifest-pre.json"
$pre | ConvertTo-Json -Depth 10 | Set-Content -Path $prePath -Encoding UTF8

$buildDir = Join-Path $source "WebKitBuild"
$preserveBuildDir = $false
if ($null -ne $config.PSObject.Properties["preserveBuildDir"]) {
  $preserveBuildDir = [bool]$config.preserveBuildDir
}
if ((Test-Path $buildDir) -and -not $preserveBuildDir) {
  Remove-Item -Recurse -Force $buildDir
} elseif ((Test-Path $buildDir) -and $preserveBuildDir) {
  Write-Host "Preserving existing build directory for fast retry: $buildDir"
}

Enable-SymlinkEvaluation
Invoke-BuildCmd -VsDevCmd $config.vsDevCmdPath -WorkingDir $source -CmdLine $config.buildCommandLine

$out = $config.outputDir
if (-not (Test-Path $out)) {
  throw "Expected output directory missing: $out"
}

$cache = Join-Path $out "CMakeCache.txt"
if (-not (Test-Path $cache)) {
  throw "CMakeCache.txt missing under $out"
}

if ($null -ne $config.PSObject.Properties["enableSccache"] -and [bool]$config.enableSccache) {
  $logFile = Join-Path $artDir ("build-webkit-" + $config.buildId + ".log")
  $ninjaFile = Join-Path $out "build.ninja"
  $cacheText = Get-Content $cache -Raw
  $ninjaText = if (Test-Path $ninjaFile) { Get-Content $ninjaFile -Raw } else { "" }
  $sccacheLogTail = if (Test-Path $logFile) { @(Get-Content $logFile -Tail 120 | ForEach-Object { [string]$_ }) } else { @() }
  $sccacheStats = $sccacheLogTail | Where-Object { $_ -match '^Compile requests\s+[0-9]+\s*$' } | Select-Object -Last 1
  $sccacheExecutedStats = $sccacheLogTail | Where-Object { $_ -match '^Compile requests executed\s+[0-9]+\s*$' } | Select-Object -Last 1
  $sccacheHitStats = $sccacheLogTail | Where-Object { $_ -match '^Cache hits\s+[0-9]+\s*$' } | Select-Object -Last 1
  $sccacheMissStats = $sccacheLogTail | Where-Object { $_ -match '^Cache misses\s+[0-9]+\s*$' } | Select-Object -Last 1
  $sccacheHitRateStats = $sccacheLogTail | Where-Object { $_ -match '^Cache hits rate\s+' } | Select-Object -Last 1
  $normalizedSccacheExe = $config.sccacheExe.Replace('\', '/')
  $sccacheExeName = Split-Path -Leaf $config.sccacheExe
  $normalizedCacheText = $cacheText.Replace('\', '/')
  $normalizedNinjaText = $ninjaText.Replace('\', '/')
  $cacheHasLauncher = $cacheText -match 'CMAKE_C_COMPILER_LAUNCHER' -and $cacheText -match 'CMAKE_CXX_COMPILER_LAUNCHER' -and ($normalizedCacheText -match [regex]::Escape($normalizedSccacheExe) -or $cacheText -match [regex]::Escape($sccacheExeName))
  $ninjaHasLauncher = $normalizedNinjaText -match [regex]::Escape($normalizedSccacheExe) -or $ninjaText -match [regex]::Escape($sccacheExeName)
  $cacheHasEmbeddedDebugInfo = $cacheText -match 'CMAKE_MSVC_DEBUG_INFORMATION_FORMAT(:[A-Z]+)?=Embedded'
  $requests = $null
  if ($sccacheStats -match '^Compile requests\s+([0-9]+)\s*$') {
    $requests = [int]$Matches[1]
  }
  $requestsExecuted = $null
  if ($sccacheExecutedStats -match '^Compile requests executed\s+([0-9]+)\s*$') {
    $requestsExecuted = [int]$Matches[1]
  }
  $cacheHits = $null
  if ($sccacheHitStats -match '^Cache hits\s+([0-9]+)\s*$') {
    $cacheHits = [int]$Matches[1]
  }
  $cacheMisses = $null
  if ($sccacheMissStats -match '^Cache misses\s+([0-9]+)\s*$') {
    $cacheMisses = [int]$Matches[1]
  }
  $sccacheReport = [ordered]@{
    requested = $true
    exe = $config.sccacheExe
    cacheDir = $config.sccacheDir
    cmakeCacheHasLauncher = $cacheHasLauncher
    ninjaHasLauncher = $ninjaHasLauncher
    cmakeCacheHasEmbeddedDebugInfo = $cacheHasEmbeddedDebugInfo
    compileRequests = $requests
    compileRequestsExecuted = $requestsExecuted
    cacheHits = $cacheHits
    cacheMisses = $cacheMisses
    cacheHitsRate = $sccacheHitRateStats
    statsLine = $sccacheStats
  }
  $sccacheReport | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $artDir "sccache-report.json") -Encoding UTF8
  if (-not $cacheHasLauncher) {
    throw "sccache was requested but CMakeCache.txt does not contain CMAKE_*_COMPILER_LAUNCHER=$($config.sccacheExe)."
  }
  if (-not $ninjaHasLauncher) {
    throw "sccache was requested but build.ninja does not invoke $($config.sccacheExe)."
  }
  if (-not $cacheHasEmbeddedDebugInfo) {
    throw "sccache was requested but CMakeCache.txt does not contain CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded."
  }
  if ($requests -eq 0 -or ($null -eq $requests -and $requestsExecuted -eq 0)) {
    throw "sccache was requested and configured but recorded zero compile requests. This build was effectively cold."
  }
}

$bin = Join-Path $out "bin"
$required = @("MiniBrowser.exe", "WebKit2.dll", "WebCore.dll", "JavaScriptCore.dll")
foreach ($r in $required) {
  $rp = Join-Path $bin $r
  if (-not (Test-Path $rp)) {
    throw "Missing required artifact: $rp"
  }
}

$mb = Join-Path $bin "MiniBrowser.exe"
$mbh = Get-FileHash $mb -Algorithm SHA256
$cmakeLines = Get-Content $cache | Where-Object {
  $_ -match '^(PORT:|ENABLE_WEBGPU|ENABLE_MINIBROWSER|CMAKE_BUILD_TYPE):'
}
$webgpuEnabled = ($cmakeLines | Where-Object { $_ -match 'ENABLE_WEBGPU:BOOL=ON' }).Count -gt 0

# --- Self-heal: copy Dawn runtime DLLs from this build's vcpkg tree ---
if ($webgpuEnabled) {
  $vcpkgBin = Join-Path $out "vcpkg_installed\x64-windows-webkit\bin"
  if (Test-Path $vcpkgBin) {
    Get-ChildItem $vcpkgBin -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
      $target = Join-Path $bin $_.Name
      if (-not (Test-Path $target)) {
        Copy-Item $_.FullName $target -Force
        Write-Host "Copied runtime DLL from vcpkg: $($_.Name)"
      }
    }
  }

  $dawnDll = Join-Path $bin "webgpu_dawn.dll"
  if (-not (Test-Path $dawnDll)) {
    $vcpkgDawn = "C:/vcpkg/installed/x64-windows-webkit/bin/webgpu_dawn.dll"
    if (Test-Path $vcpkgDawn) {
      Copy-Item $vcpkgDawn $dawnDll -Force
      Write-Host "Copied webgpu_dawn.dll from vcpkg"
    }
  }

  # Dawn and Abseil are ABI-tied by Abseil's inline namespace. Some builder
  # states have WebKit's private vcpkg tree on abseil lts_20250814 while the
  # installed Dawn DLL imports lts_20260107 symbols. Prefer the matching global
  # vcpkg Abseil DLL whenever present so webgpu_dawn.dll can load.
  $globalAbseil = "C:/vcpkg/installed/x64-windows-webkit/bin/abseil_dll.dll"
  if (Test-Path $globalAbseil) {
    Copy-Item $globalAbseil (Join-Path $bin "abseil_dll.dll") -Force
    Write-Host "Copied Dawn-matching abseil_dll.dll from global vcpkg"
  }
}

# --- Validation phase: LoadLibrary deps check + MiniBrowser runtime probe ---
function Test-DllLoad {
  param([string]$Path)
  Add-Type -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("kernel32", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
    public static extern System.IntPtr LoadLibraryEx(string dllToLoad, System.IntPtr hFile, uint flags);
    [System.Runtime.InteropServices.DllImport("kernel32", SetLastError=true)]
    public static extern bool FreeLibrary(System.IntPtr hModule);
"@ -Name Kernel32Loader -Namespace NgWebkit -ErrorAction SilentlyContinue
  # LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008 (so dependent DLLs in same dir are found)
  $h = [NgWebkit.Kernel32Loader]::LoadLibraryEx($Path, [System.IntPtr]::Zero, 0x00000008)
  if ($h -eq [System.IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return @{ loaded = $false; win32Error = $err }
  }
  [NgWebkit.Kernel32Loader]::FreeLibrary($h) | Out-Null
  return @{ loaded = $true }
}

$validation = [ordered]@{
  buildId = $config.buildId
  timestamp = (Get-Date).ToUniversalTime().ToString("o")
  webgpuEnabled = $webgpuEnabled
  files = [ordered]@{}
  dllLoad = [ordered]@{}
  runtime = $null
}

# File presence
$expectedFiles = @("MiniBrowser.exe","MiniBrowserInjectedBundle.dll","WebKit2.dll","WebCore.dll","JavaScriptCore.dll","libEGL.dll","libGLESv2.dll")
if ($webgpuEnabled) { $expectedFiles += "webgpu_dawn.dll" }
foreach ($f in $expectedFiles) {
  $fp = Join-Path $bin $f
  $validation.files[$f] = Test-Path $fp
}

# LoadLibrary test for key DLLs
$dllsToTest = @("WebKit2.dll","WebCore.dll","JavaScriptCore.dll","libEGL.dll","libGLESv2.dll")
if ($webgpuEnabled) { $dllsToTest += "webgpu_dawn.dll" }
foreach ($d in $dllsToTest) {
  $dp = Join-Path $bin $d
  if (Test-Path $dp) {
    $validation.dllLoad[$d] = Test-DllLoad -Path $dp
  } else {
    $validation.dllLoad[$d] = @{ loaded = $false; missing = $true }
  }
}

# Runtime probe: launch MiniBrowser with a test HTML + HttpListener callback
$probePort = 18787
$testHtmlPath = Join-Path $artDir "validate-probe.html"
$testHtml = @"
<!doctype html><html><head><meta charset="utf-8"><title>ng-webkit validate</title></head>
<body><h1>ng-webkit validation probe</h1><pre id="out">running...</pre>
<script>
(async () => {
  function toArray(value) {
    try { return Array.from(value || []); } catch (e) { return []; }
  }

  function pickLimits(limits) {
    if (!limits) return null;
    const keys = [
      'maxTextureDimension1D',
      'maxTextureDimension2D',
      'maxTextureArrayLayers',
      'maxBindGroups',
      'maxBindingsPerBindGroup',
      'maxBufferSize',
      'maxStorageBufferBindingSize',
      'maxUniformBufferBindingSize'
    ];
    const out = {};
    for (const key of keys) {
      try {
        if (limits[key] !== undefined) out[key] = limits[key];
      } catch (e) { }
    }
    return out;
  }

  function errorString(e) {
    return String(e && (e.stack || e.message) || e);
  }

  const report = {
    userAgent: navigator.userAgent,
    gpuAvailable: !!navigator.gpu,
    preferredCanvasFormat: navigator.gpu ? navigator.gpu.getPreferredCanvasFormat() : null,
    wgslLanguageFeatures: navigator.gpu ? toArray(navigator.gpu.wgslLanguageFeatures) : [],
    adapter: null,
    adapterFeatures: [],
    adapterLimits: null,
    adapterError: null,
    device: null,
    deviceError: null,
    queueAvailable: false,
    smokePassed: false
  };
  if (navigator.gpu) {
    try {
      const a = await navigator.gpu.requestAdapter();
      if (a) {
        const info = (a.info || (a.requestAdapterInfo ? await a.requestAdapterInfo() : {}));
        report.adapter = { vendor: info.vendor, architecture: info.architecture, device: info.device, description: info.description };
        report.adapterFeatures = toArray(a.features);
        report.adapterLimits = pickLimits(a.limits);
        try {
          const device = await a.requestDevice();
          report.device = {
            features: toArray(device.features),
            limits: pickLimits(device.limits)
          };
          report.queueAvailable = !!device.queue;
          report.smokePassed = !!device.queue;
          if (device.destroy) device.destroy();
        } catch (e) {
          report.deviceError = errorString(e);
        }
      } else {
        report.adapterError = 'requestAdapter returned null';
      }
    } catch (e) { report.adapterError = errorString(e); }
  }
  document.getElementById('out').textContent = JSON.stringify(report, null, 2);
  try {
    await fetch('http://localhost:$probePort/report', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(report)
    });
  } catch (e) { /* ignore — validation will timeout */ }
})();
</script></body></html>
"@
Set-Content -Path $testHtmlPath -Value $testHtml -Encoding UTF8
$testHtmlUrl = "file:///" + ($testHtmlPath -replace '\\','/')

# HttpListener in background runspace so we can launch MiniBrowser after
$listenerScript = {
  param($port)
  $l = [System.Net.HttpListener]::new()
  $l.Prefixes.Add("http://localhost:$port/")
  $l.Start()
  $ctx = $l.GetContext()  # blocks until request (we rely on timeout via job)
  $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
  $body = $reader.ReadToEnd()
  $ctx.Response.StatusCode = 200
  $ctx.Response.OutputStream.Close()
  $l.Stop()
  return $body
}
$listenerJob = Start-Job -ScriptBlock $listenerScript -ArgumentList $probePort

# Launch MiniBrowser
try {
  $mbProc = Start-Process -FilePath $mb -ArgumentList $testHtmlUrl -PassThru -WindowStyle Hidden
  Write-Host "MiniBrowser launched pid=$($mbProc.Id) url=$testHtmlUrl"
  $waitResult = Wait-Job $listenerJob -Timeout 30
  if ($waitResult) {
    $reportJson = Receive-Job $listenerJob
    try {
      $validation.runtime = ($reportJson | ConvertFrom-Json)
    } catch {
      $validation.runtime = @{ error = "parse failed"; raw = $reportJson }
    }
  } else {
    $validation.runtime = @{ error = "timeout waiting for probe callback (30s)" }
    Stop-Job $listenerJob -ErrorAction SilentlyContinue
  }
} catch {
  $validation.runtime = @{ error = "MiniBrowser launch failed: $($_.Exception.Message)" }
} finally {
  try {
    if ($mbProc -and -not $mbProc.HasExited) { $mbProc.Kill() | Out-Null }
  } catch {}
  Remove-Job $listenerJob -Force -ErrorAction SilentlyContinue
}

$validationPath = Join-Path $config.workdir "validation-report.json"
$validation | ConvertTo-Json -Depth 10 | Set-Content -Path $validationPath -Encoding UTF8
Write-Host "Validation written to $validationPath"

$cmakeCacheSummaryPath = Join-Path $config.workdir "cmake-cache-summary.txt"
@($cmakeLines) | Set-Content -Path $cmakeCacheSummaryPath -Encoding UTF8

# Keep the post manifest deliberately small and acyclic. ConvertTo-Json can spend
# unbounded time walking PowerShell objects if a native command/job object leaks
# into this graph, and previous green builds were stranded here before upload.
$post = [ordered]@{
  miniBrowserSha256 = $mbh.Hash
  webgpuEnabled = $webgpuEnabled
  validationReport = "validation-report.json"
  cmakeCacheSummary = "cmake-cache-summary.txt"
}
$postPath = Join-Path $config.workdir "manifest-post.json"
Write-Host "Writing post manifest to $postPath"
$post | ConvertTo-Json -Depth 10 | Set-Content -Path $postPath -Encoding UTF8
Write-Host "Post manifest written"

Copy-Item $prePath $artDir
Copy-Item $postPath $artDir
Copy-Item $validationPath $artDir
Copy-Item $cmakeCacheSummaryPath $artDir
if (Test-Path $patchManifestPath) {
  Copy-Item $patchManifestPath $artDir
}
if ($config.bootstrap -and (Test-Path $config.bootstrap)) {
  Copy-Item (Join-Path $config.bootstrap "*.log") $artDir -ErrorAction SilentlyContinue
}

# Archive only bin/ (distributable binaries + DLLs). Use tar (available on Win10+/Server 2019+)
# instead of Compress-Archive which is single-threaded and hangs on large directories.
$binDir = Join-Path $out "bin"
$archivePath = Join-Path $artDir ("ng-webkit-windows-" + $config.buildId + ".tar.gz")
Write-Host "Creating archive $archivePath from $binDir"
Push-Location $binDir
tar -czf $archivePath .
Pop-Location
if (-not (Test-Path $archivePath)) {
  throw "Archive creation failed: $archivePath"
}
Write-Host "Archive created: $archivePath"
