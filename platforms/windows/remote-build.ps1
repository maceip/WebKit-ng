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
  if ($output) { $output | ForEach-Object { Write-Host $_ } }
  return ($exitCode -eq 0)
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here "build-config.json"
if (-not (Test-Path $configPath)) {
  throw "build-config.json not found: $configPath"
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

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
  [void]$lines.Add("cd /d `"$WorkingDir`"")
  [void]$lines.Add("$CmdLine >> `"$logFile`" 2>&1")
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

$patchRoot = Join-Path $here "patches"
$commonPatches = @(Get-ChildItem (Join-Path $patchRoot "common") -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name)
$winPatches = @(Get-ChildItem (Join-Path $patchRoot "windows") -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name)

$source = $null
if ($config.useCleanCheckout -eq $true) {
  $cleanRoot = $config.cleanSourceRoot
  if (Test-Path $cleanRoot) {
    Remove-Item -Recurse -Force $cleanRoot
  }
  New-Item -ItemType Directory -Force -Path (Split-Path $cleanRoot) | Out-Null
  Invoke-Git config --global core.longpaths true

  $commit = $config.webkitCommit
  $sparse = @($config.sparseCheckoutPaths)
  if ($sparse.Count -gt 0) {
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
if (Test-Path $buildDir) {
  Remove-Item -Recurse -Force $buildDir
}

Invoke-BuildCmd -VsDevCmd $config.vsDevCmdPath -WorkingDir $source -CmdLine $config.buildCommandLine

$out = $config.outputDir
if (-not (Test-Path $out)) {
  throw "Expected output directory missing: $out"
}

$cache = Join-Path $out "CMakeCache.txt"
if (-not (Test-Path $cache)) {
  throw "CMakeCache.txt missing under $out"
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
  const report = {
    userAgent: navigator.userAgent,
    gpuAvailable: !!navigator.gpu,
    adapter: null,
    adapterError: null
  };
  if (navigator.gpu) {
    try {
      const a = await navigator.gpu.requestAdapter();
      if (a) {
        const info = (a.info || (a.requestAdapterInfo ? await a.requestAdapterInfo() : {}));
        report.adapter = { vendor: info.vendor, architecture: info.architecture, device: info.device, description: info.description };
      } else {
        report.adapterError = 'requestAdapter returned null';
      }
    } catch (e) { report.adapterError = String(e); }
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
