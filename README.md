# ng-webkit

Build orchestration for patched WebKit/WPE WebKit targets.

Current targets:

- `android`: WPE Android/WPEWebKit, built locally on this machine.
- `windows`: remote Windows builder driven through AWS SSM, with artifacts in S3.
- `linux`, `ios`, `macos`: placeholders for the next platform scripts.

The repo owns the patch set and orchestration. Platform source checkouts live outside
the repo by default so large WebKit trees and build products do not pollute this git
history.

## Layout

- `patches/common`: patches applied to every source tree when applicable.
- `patches/android`: Android/WPE Android specific patches.
- `patches/windows`: Windows specific patches.
- `platforms/*`: setup and build entry points per platform.
- `scripts`: shared patch, artifact, and build helpers.
- `service`: local HTTP API for starting, restarting, checkpointing, and tracking builds.

Patch files should be standard `git format-patch` or `git diff` patches with `.patch`
or `.diff` suffixes. The build scripts apply `patches/common` first, then the platform
patch directory.

## Configuration

Copy `.env.example` to `.env` or export the values in your shell.

Important defaults on this machine:

- `ANDROID_HOME=/home/ubuntu/Android/Sdk`
- `NG_ANDROID_SOURCE=/home/ubuntu/webkit/wpe-android`
- `NG_WINDOWS_ARTIFACT_S3=s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows`

Windows SSM is prefilled for the successful build machine:

- instance `i-0d254760fe07c5e9f`
- name `webkit-win-build-20260412`
- region `eu-west-1`
- source `C:\Work\WebKit`
- output `C:\Work\WebKit\WebKitBuild\Release`
- bootstrap/log area `C:\Bootstrap`
- vcpkg `C:\vcpkg`
- Visual Studio Build Tools `C:\BuildTools`
- Ruby `C:\Ruby34-x64`
- LLVM `C:\Program Files\LLVM`
- isolated gperf toolbin `C:\Bootstrap\toolbin`
- known-good artifacts `s3://cory-build-artifacts-euc1-095713295645-20260407/webkit/windows-build29-20260413`

Override those with `.env` when using a different Windows builder.

List the known-good Windows baseline:

```bash
./platforms/windows/list-artifacts.sh
```

## Running a Build

Local script:

```bash
./scripts/run-build.sh android
./scripts/run-build.sh windows
```

Build service:

```bash
cd service
npm install
npm start
```

Then:

```bash
curl -s -X POST http://127.0.0.1:8787/builds \
  -H 'content-type: application/json' \
  -d '{"platforms":["android","windows"],"reason":"test build"}'
```

Useful endpoints:

- `GET /builds`
- `GET /builds/:id`
- `POST /builds/:id/checkpoint`
- `POST /builds/:id/restart`
- `POST /builds/:id/cancel`
