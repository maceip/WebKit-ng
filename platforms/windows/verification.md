# Windows Build Verification

Verified on 2026-04-14 against the Windows builder and S3 artifact prefix.

## Builder

- Instance: `i-0d254760fe07c5e9f`
- Name: `webkit-win-build-20260412`
- Region: `eu-west-1`
- OS: Microsoft Windows Server 2022 Datacenter
- Build tree: `C:\Work\WebKit\WebKitBuild\Release`
- Source tree: `C:\Work\WebKit`

## S3 Artifacts

Prefix:

`s3://cory-build-artifacts-euc1-095713295645-20260407/webkit/windows-build29-20260413/`

Observed total: 14 objects, 11.4 GiB.

Important artifacts:

- `MiniBrowser.zip` - 71.1 MiB
- `release-bin.tar` - 2.4 GiB
- `release-lib.tar` - 255.3 MiB
- `release-tools.tar` - 313.5 MiB
- `release-vcpkg_installed.tar` - 747.9 MiB
- `remote-bootstrap-logs.tar` - 857.0 MiB
- `webkit-build29-repro.tar` - 219 KiB

`MiniBrowser.zip` SHA-256:

`de98c035f90b0972020c9a3be86a6ab1ad6ec1fb2391cfc0ac52515155d6575f`

## Build Result Evidence

The remote build log `C:\Bootstrap\webkit-build29-stdout.log` ends with:

- `[5820/5823] Linking CXX shared library bin\MiniBrowserInjectedBundle.dll`
- `[5821/5823] Linking CXX executable bin\MiniBrowser.exe`
- `[5822/5823] Linking CXX executable bin\TestWebKit.exe`
- `[5823/5823] Linking CXX executable bin\WebKitTestRunner.exe`
- `WebKit is now built (31m:05s).`

The matching stderr log is empty.

## Remote Binary Evidence

Present in `C:\Work\WebKit\WebKitBuild\Release\bin`:

- `MiniBrowser.exe`
- `MiniBrowserInjectedBundle.dll`
- `WebKit2.dll`
- `WebCore.dll`
- `JavaScriptCore.dll`
- `WebKitWebProcess.exe`
- `WebKitNetworkProcess.exe`
- `WebKitGPUProcess.exe`
- `WebKitTestRunner.exe`
- `WebDriver.exe`
- `jsc.exe`

CMake cache confirms:

- `PORT:STRING=Win`
- `CMAKE_BUILD_TYPE:STRING=Release`
- `ENABLE_MINIBROWSER:BOOL=ON`
- `CMAKE_CXX_COMPILER:STRING=C:/Program Files/LLVM/bin/clang-cl.exe`

Smoke test on the Windows host:

`jsc.exe -e "print('ng-webkit-jsc-smoke:' + (21+21))"`

Output:

`ng-webkit-jsc-smoke:42`

Exit code: `0`.

## Caveats

- This is a native WebKit `PORT=Win` / WinCairo-style build, not proof of a WPE Windows backend build.
- The output binaries are real, but the source provenance is not clean enough to call this a reproducible accepted build.
- The live Windows source tree is on upstream `main` commit `52dbebe20b922cab89928085f9dcfa8082a813e4` with local dirty edits.
- The handoff/repro metadata says `base_commit=c46301f7ed90925848f626dae58071407d077bd3`.
- The `maceip/WebKit:dawn` branch resolves to `a836cab7bc76bc2c29b298854f84276842470572`, based on `c46301f7`, and contains the Dawn/WebGPU and inspector changes as commits/files.
- The live source tree has local modifications and `.rej` files from prior patch attempts. These must be normalized into `changes/*` and `patches/windows` before relying on reproducible rebuilds.
- I did not launch `MiniBrowser.exe` interactively. The verification proves the binary exists, links as part of the build, is uploaded in `MiniBrowser.zip`, and JavaScriptCore executes.

## Follow-Up Build Gate

For the next Windows acceptance build, use a clean checkout of `maceip/WebKit:dawn` at `a836cab7bc76bc2c29b298854f84276842470572` or a later explicit commit. The build must write and upload a manifest containing:

- source commit and branch
- `git status --porcelain`
- applied patch list
- CMake cache
- build logs
- artifact hashes

Acceptance needs both checks:

- MiniBrowser launches and right-click `Show Inspector` works.
- WebGPU/Dawn configuration is intentionally enabled and visible in `CMakeCache.txt`.

---
