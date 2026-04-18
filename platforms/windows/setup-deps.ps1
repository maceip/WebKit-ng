#Requires -Version 5.1
<#
  Provision an ng-webkit Windows build host.

  This script is intentionally idempotent. It installs the toolchain locations
  assumed by platforms/windows/build.sh and platforms/windows/remote-build.ps1:

    C:\Program Files\Git\cmd
    C:\Ruby34-x64
    C:\Strawberry
    C:\Program Files\CMake\bin
    C:\Program Files\LLVM\bin
    C:\BuildTools\Common7\Tools\VsDevCmd.bat
    C:\vcpkg
    C:\Bootstrap\toolbin
    C:\Bootstrap\toolbin\gperf.exe

  The bash wrapper ships this file to the Windows machine through SSM.
#>

param(
  [string]$Bootstrap = "C:\Bootstrap",
  [string]$Toolbin = "C:\Bootstrap\toolbin",
  [string]$VcpkgRoot = "C:\vcpkg",
  [string]$VsInstallPath = "C:\BuildTools",
  [string]$RubyRoot = "C:\Ruby34-x64",
  [string]$PythonRoot = "C:\Python314",
  [string]$StrawberryRoot = "C:\Strawberry",
  [string]$BaselineS3Prefix = "s3://cory-build-artifacts-euc1-095713295645-20260407/webkit/windows-build29-20260413",
  [string]$BaselineS3Region = "eu-central-1",
  [switch]$RestoreBaselineVcpkg,
  [switch]$RequireDawn
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
  param([string]$Message)
  Write-Host "==> $Message"
}

function New-Dir {
  param([string]$Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [int[]]$SuccessExitCodes = @(0)
  )
  Write-Host "+ $FilePath $($ArgumentList -join ' ')"
  $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
  if ($SuccessExitCodes -notcontains $p.ExitCode) {
    throw "$FilePath exited with $($p.ExitCode)"
  }
}

function Invoke-Download {
  param([string]$Uri, [string]$OutFile)
  for ($i = 1; $i -le 4; $i++) {
    try {
      Write-Host "Downloading $Uri"
      Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
      return
    } catch {
      if ($i -eq 4) { throw }
      Start-Sleep -Seconds ([math]::Min(30, 5 * $i))
    }
  }
}

function Get-GithubAsset {
  param(
    [string]$Repo,
    [string]$Pattern
  )
  $headers = @{ "User-Agent" = "ng-webkit-builder-provision" }
  $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=25" -Headers $headers
  $asset = $releases | ForEach-Object { $_.assets } | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
  if (-not $asset) {
    throw "No asset matching '$Pattern' in recent $Repo releases."
  }
  return $asset.browser_download_url
}

function Add-SystemPath {
  param([string[]]$Entries)
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $parts = @()
  if ($machinePath) {
    $parts = @($machinePath -split ";" | Where-Object { $_ })
  }
  $changed = $false
  foreach ($entry in $Entries) {
    if (-not $entry) { continue }
    if ($parts -notcontains $entry) {
      $parts += $entry
      $changed = $true
    }
    if (($env:PATH -split ";") -notcontains $entry) {
      $env:PATH = "$entry;$env:PATH"
    }
  }
  if ($changed) {
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "Machine")
  }
}

function Ensure-RegistryLongPaths {
  Write-Step "Enable Windows long paths"
  New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Force | Out-Null
  New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -PropertyType DWord -Value 1 -Force | Out-Null
}

function Ensure-Git {
  if (Test-Path "C:\Program Files\Git\cmd\git.exe") {
    Write-Step "Git already installed"
    return
  }
  Write-Step "Install Git for Windows"
  $url = Get-GithubAsset -Repo "git-for-windows/git" -Pattern "^Git-.*-64-bit\.exe$"
  $exe = Join-Path $Bootstrap "installers\git-installer.exe"
  Invoke-Download $url $exe
  Invoke-Native $exe @("/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-", "/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh")
}

function Ensure-Ruby {
  if (Test-Path (Join-Path $RubyRoot "bin\ruby.exe")) {
    Write-Step "Ruby already installed"
    return
  }
  Write-Step "Install RubyInstaller"
  $url = Get-GithubAsset -Repo "oneclick/rubyinstaller2" -Pattern "^rubyinstaller-3\.4\..*-x64\.exe$"
  $exe = Join-Path $Bootstrap "installers\rubyinstaller.exe"
  Invoke-Download $url $exe
  Invoke-Native $exe @("/verysilent", "/norestart", "/dir=$RubyRoot", "/tasks=modpath")
}

function Ensure-StrawberryPerl {
  if (Test-Path (Join-Path $StrawberryRoot "perl\bin\perl.exe")) {
    Write-Step "Strawberry Perl already installed"
    return
  }
  Write-Step "Install Strawberry Perl"
  $url = Get-GithubAsset -Repo "StrawberryPerl/Perl-Dist-Strawberry" -Pattern "^strawberry-perl-.*-64bit\.msi$"
  $msi = Join-Path $Bootstrap "installers\strawberry-perl.msi"
  Invoke-Download $url $msi
  Invoke-Native "msiexec.exe" @("/i", $msi, "/qn", "/norestart", "INSTALLDIR=$StrawberryRoot") @(0, 3010)
}

function Ensure-Python {
  $pythonExe = Join-Path $PythonRoot "python.exe"
  if (Test-Path $pythonExe) {
    Write-Step "Python already installed"
    return
  }
  Write-Step "Install Python"
  $url = "https://www.python.org/ftp/python/3.14.4/python-3.14.4-amd64.exe"
  $exe = Join-Path $Bootstrap "installers\python-installer.exe"
  Invoke-Download $url $exe
  Invoke-Native $exe @("/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_test=0", "TargetDir=$PythonRoot") @(0, 3010)
}

function Ensure-CMake {
  if (Test-Path "C:\Program Files\CMake\bin\cmake.exe") {
    Write-Step "CMake already installed"
    return
  }
  Write-Step "Install CMake"
  $url = Get-GithubAsset -Repo "Kitware/CMake" -Pattern "^cmake-.*-windows-x86_64\.msi$"
  $msi = Join-Path $Bootstrap "installers\cmake.msi"
  Invoke-Download $url $msi
  Invoke-Native "msiexec.exe" @("/i", $msi, "/qn", "/norestart", "ADD_CMAKE_TO_PATH=System") @(0, 3010)
}

function Ensure-LLVM {
  if (Test-Path "C:\Program Files\LLVM\bin\clang-cl.exe") {
    Write-Step "LLVM already installed"
    return
  }
  Write-Step "Install LLVM"
  $url = Get-GithubAsset -Repo "llvm/llvm-project" -Pattern "^LLVM-.*-win64\.exe$"
  $exe = Join-Path $Bootstrap "installers\llvm-installer.exe"
  Invoke-Download $url $exe
  Invoke-Native $exe @("/S", "/D=C:\Program Files\LLVM")
}

function Ensure-AwsCli {
  $aws = Join-Path $env:ProgramFiles "Amazon\AWSCLIV2\aws.exe"
  if (Test-Path $aws) {
    Write-Step "AWS CLI already installed"
    return
  }
  Write-Step "Install AWS CLI v2"
  $msi = Join-Path $Bootstrap "installers\awscliv2.msi"
  Invoke-Download "https://awscli.amazonaws.com/AWSCLIV2.msi" $msi
  Invoke-Native "msiexec.exe" @("/i", $msi, "/qn", "/norestart") @(0, 3010)
}

function Ensure-VisualStudioBuildTools {
  $vsDevCmd = Join-Path $VsInstallPath "Common7\Tools\VsDevCmd.bat"
  if (Test-Path $vsDevCmd) {
    Write-Step "Visual Studio Build Tools already installed"
    return
  }
  Write-Step "Install Visual Studio Build Tools"
  $exe = Join-Path $Bootstrap "installers\vs_buildtools.exe"
  Invoke-Download "https://aka.ms/vs/17/release/vs_buildtools.exe" $exe
  $args = @(
    "--quiet", "--wait", "--norestart", "--nocache",
    "--installPath", $VsInstallPath,
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add", "Microsoft.VisualStudio.Component.VC.ATL",
    "--add", "Microsoft.VisualStudio.Component.VC.ATLMFC",
    "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
    "--includeRecommended"
  )
  Invoke-Native $exe $args @(0, 3010)
}

function Ensure-Sccache {
  $sccacheExe = Join-Path $Toolbin "sccache.exe"
  if (Test-Path $sccacheExe) {
    Write-Step "sccache already installed"
    return
  }
  Write-Step "Install sccache"
  $url = Get-GithubAsset -Repo "mozilla/sccache" -Pattern "x86_64-pc-windows-msvc.*\.zip$"
  $zip = Join-Path $Bootstrap "installers\sccache.zip"
  $extract = Join-Path $Bootstrap "installers\sccache"
  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  Invoke-Download $url $zip
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  $downloaded = Get-ChildItem -Path $extract -Recurse -Filter "sccache.exe" | Select-Object -First 1
  if (-not $downloaded) { throw "sccache archive did not contain sccache.exe" }
  Copy-Item $downloaded.FullName $sccacheExe -Force
}

function Ensure-Vcpkg {
  if (Test-Path (Join-Path $VcpkgRoot "vcpkg.exe")) {
    Write-Step "vcpkg already bootstrapped"
    return
  }
  Write-Step "Install vcpkg"
  if (-not (Test-Path $VcpkgRoot)) {
    Invoke-Native "git.exe" @("clone", "https://github.com/microsoft/vcpkg.git", $VcpkgRoot)
  }
  Invoke-Native "cmd.exe" @("/c", (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat"), "-disableMetrics")
}

function Ensure-Gperf {
  $gperfExe = Join-Path $Toolbin "gperf.exe"
  if (Test-Path $gperfExe) {
    Write-Step "gperf already installed"
    return
  }

  Write-Step "Install gperf through vcpkg"
  $vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
  if (-not (Test-Path $vcpkgExe)) {
    throw "Cannot install gperf before vcpkg is bootstrapped: $vcpkgExe"
  }

  Add-SystemPath @("C:\Program Files\Git\cmd", "C:\Program Files\Git\bin")
  Invoke-Native $vcpkgExe @("install", "gperf:x64-windows") @(0)
  $installed = Get-ChildItem -Path $VcpkgRoot -Recurse -File -Filter "gperf.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $installed) {
    throw "vcpkg install gperf completed but gperf.exe was not found under $VcpkgRoot"
  }
  Copy-Item $installed.FullName $gperfExe -Force
}

function Restore-BaselineVcpkg {
  if (-not $RestoreBaselineVcpkg) { return }
  $dawnDll = Join-Path $VcpkgRoot "installed\x64-windows-webkit\bin\webgpu_dawn.dll"
  if ((Test-Path $dawnDll) -and (Test-Path (Join-Path $VcpkgRoot "installed\x64-windows-webkit\include\dawn\webgpu.h"))) {
    Write-Step "Baseline vcpkg Dawn payload already present"
    return
  }

  Write-Step "Restore known-good vcpkg_installed payload from S3"
  $aws = Join-Path $env:ProgramFiles "Amazon\AWSCLIV2\aws.exe"
  if (-not (Test-Path $aws)) { $aws = "aws.exe" }
  $archive = Join-Path $Bootstrap "installers\release-vcpkg_installed.tar"
  Invoke-Native $aws @("s3", "cp", "$BaselineS3Prefix/release-vcpkg_installed.tar", $archive, "--region", $BaselineS3Region)
  # Keep the extraction root short. The vcpkg tree contains very deep include
  # and pkgconfig paths, and Windows bsdtar can fail before long-path handling
  # helps if the temporary extraction root is too verbose.
  $extract = "C:\B\v"
  if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
  New-Dir $extract
  Invoke-Native "tar.exe" @("-xf", $archive, "-C", $extract)

  $triplet = Get-ChildItem -Path $extract -Recurse -Directory -Filter "x64-windows-webkit" | Select-Object -First 1
  if (-not $triplet) {
    throw "release-vcpkg_installed.tar did not contain x64-windows-webkit"
  }
  New-Dir (Join-Path $VcpkgRoot "installed")
  $targetTriplet = Join-Path $VcpkgRoot "installed\x64-windows-webkit"
  if (Test-Path $targetTriplet) { Remove-Item -Recurse -Force $targetTriplet }
  Copy-Item $triplet.FullName $targetTriplet -Recurse -Force
}

function Test-RequiredPaths {
  $checks = [ordered]@{
    git = "C:\Program Files\Git\cmd\git.exe"
    ruby = (Join-Path $RubyRoot "bin\ruby.exe")
    python = (Join-Path $PythonRoot "python.exe")
    perl = (Join-Path $StrawberryRoot "perl\bin\perl.exe")
    cmake = "C:\Program Files\CMake\bin\cmake.exe"
    clangCl = "C:\Program Files\LLVM\bin\clang-cl.exe"
    vsDevCmd = (Join-Path $VsInstallPath "Common7\Tools\VsDevCmd.bat")
    ninja = (Join-Path $VsInstallPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe")
    vcpkg = (Join-Path $VcpkgRoot "vcpkg.exe")
    sccache = (Join-Path $Toolbin "sccache.exe")
    gperf = (Join-Path $Toolbin "gperf.exe")
  }
  if ($RequireDawn) {
    $checks["dawnHeader"] = (Join-Path $VcpkgRoot "installed\x64-windows-webkit\include\dawn\webgpu.h")
    $checks["dawnDll"] = (Join-Path $VcpkgRoot "installed\x64-windows-webkit\bin\webgpu_dawn.dll")
  }

  $result = [ordered]@{}
  $missing = @()
  foreach ($key in $checks.Keys) {
    $path = $checks[$key]
    $exists = Test-Path $path
    $result[$key] = @{ path = $path; exists = $exists }
    if (-not $exists) { $missing += "$key=$path" }
  }
  $resultPath = Join-Path $Bootstrap "setup-deps-result.json"
  $result | ConvertTo-Json -Depth 5 | Set-Content -Path $resultPath -Encoding UTF8
  if ($missing.Count -gt 0) {
    throw "Windows dependency setup incomplete: $($missing -join ', ')"
  }
  Write-Step "Windows dependency setup complete"
  Write-Host "Result: $resultPath"
}

if (-not (Test-Admin)) {
  throw "Windows dependency setup must run as Administrator/SYSTEM."
}

New-Dir $Bootstrap
New-Dir $Toolbin
New-Dir (Join-Path $Bootstrap "installers")
$transcript = Join-Path $Bootstrap ("setup-deps-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + ".log")
Start-Transcript -Path $transcript -Force | Out-Null
try {
  $bootDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceId='C:'" -ErrorAction SilentlyContinue
  if ($bootDisk) {
    $gib = [math]::Floor([double]$bootDisk.FreeSpace / 1GB)
    Write-Host "C: free space before provisioning: ~$gib GiB (plan enough headroom for vcpkg + WebKit + sccache)"
  }
  Ensure-RegistryLongPaths
  Ensure-AwsCli
  Ensure-Git
  Add-SystemPath @("C:\Program Files\Git\cmd", "C:\Program Files\Git\usr\bin")
  Ensure-VisualStudioBuildTools
  Ensure-Ruby
  Ensure-Python
  Ensure-StrawberryPerl
  Ensure-CMake
  Ensure-LLVM
  Ensure-Sccache
  Ensure-Vcpkg
  Ensure-Gperf
  Add-SystemPath @(
    $Toolbin,
    "C:\Program Files\Git\cmd",
    "C:\Program Files\Git\usr\bin",
    (Join-Path $RubyRoot "bin"),
    $PythonRoot,
    (Join-Path $PythonRoot "Scripts"),
    "C:\Program Files\LLVM\bin",
    "C:\Program Files\CMake\bin",
    (Join-Path $VsInstallPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"),
    (Join-Path $StrawberryRoot "perl\bin")
  )
  Restore-BaselineVcpkg
  Test-RequiredPaths
} finally {
  Stop-Transcript | Out-Null
  Write-Host "Transcript: $transcript"
}
