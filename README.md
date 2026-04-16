# ng-webkit

Build orchestration for patched WebKit/WPE WebKit targets.

## Build status (2026-04-16)

Latest builds, newest first:

| When (UTC)          | Platform       | Build id                                   | Result    | Notes |
| ------------------- | -------------- | ------------------------------------------ | --------- | ----- |
| 2026-04-16 02:26    | Windows+WebGPU | `dawn-d3d12-runtime-20260416T011849Z`      | ✅ **green** | 33m 55s compile, artifact uploaded, `webgpu_dawn.dll` load fixed with matching Abseil DLL |
| 2026-04-15 15:16    | macOS          | `macos-clean-20260415T151654Z`             | ❌ failed  | libwebrtc `network_constants.h` -Wconstant-conversion under Xcode 16, fix in flight |
| 2026-04-15 14:54    | Windows+WebGPU | `dawn-iovalidator-20260415T145405Z`        | ✅ **green** | 33m 29s, all 9551 targets, `ENABLE_WEBGPU=ON`, tar in S3 ([download](#downloads)) |
| 2026-04-15 14:54    | macOS          | `macos-parallel-20260415T145430Z`          | ❌ failed  | (other agent) concurrent build collision with mine |
| 2026-04-15 13:45    | Windows+WebGPU | `dawn-wgsl-20260415T134548Z`               | ❌ failed  | WGSL generator compile error, fixed in patch 0006 |
| 2026-04-15 13:25    | Windows+WebGPU | `dawn-webgpu-20260415T132500Z`             | ❌ failed  | WGSL generator 3-args bug, fixed in patch 0005 |
| 2026-04-15 12:51    | macOS          | `macos-20260415T125117Z`                   | ❌ failed  | libwebrtc boringssl rename error (concurrency with parallel build) |
| 2026-04-15 12:47    | macOS          | `macos-first-20260415T124714Z`             | ❌ failed  | `nohup + disown` didn't survive SSM session; replaced with `launchctl submit` |
| 2026-04-15 12:27    | Windows+WebGPU | `dawn-webgpu-windows-20260415T122728Z`     | ⚠️  partial | Compiled 33m 23s but `ENABLE_WEBGPU=OFF` — PRIVATE flag overrode `-D`, fixed in patch 0004 |
| 2026-04-15 11:08    | Windows        | `fix-stderr2-20260415T110839Z`             | ✅ green   | Baseline (no WebGPU), 33m 23s, tar in S3 |
| 2026-04-15 09:05    | Windows        | `green-20260415T090558Z`                   | ❌ failed  | Worker died silently — AwsExe path with spaces broke `Start-Process -ArgumentList` |
| 2026-04-14 05:09    | Android        | `20260414T050928-81903`                    | ✅ green   | Local gradle build, APKs + AAR + runtime tarballs in S3 |

Current "canonical" artifacts (latest green per platform): see
[`ASSETS.md`](./ASSETS.md). Detailed runner state, known gotchas, and
next steps: see [`RUNNER.md`](./RUNNER.md).

## Targets

- `android`: WPE Android/WPEWebKit, built locally on this machine.
- `windows`: remote Windows builder driven through AWS SSM, with artifacts in S3.
- `macos`: remote mac2-m2.metal EC2 instance driven through AWS SSM.
- `linux`, `ios`: placeholders for the next platform scripts.

The repo owns the patch set and orchestration. Platform source checkouts live outside
the repo by default so large WebKit trees and build products do not pollute this git
history.

## Downloads

The most recent green Windows + WebGPU tarball (537 MiB, extract on a Windows
host with D3D12/Vulkan):

```bash
aws s3 cp s3://cory-build-artifacts-euc1-095713295645-20260407/ng-webkit/windows/dawn-d3d12-runtime-20260416T011849Z/ng-webkit-windows-dawn-d3d12-runtime-20260416T011849Z.tar.gz \
  . --region eu-central-1
```

See [`ASSETS.md`](./ASSETS.md) for the full asset catalog and presigned URL
generation.

## Layout

- `src/ng/browser`: portable browser product layer for tabs, extensions,
  WebAuthn/passkeys, sync, and platform adapter contracts.
- `changes/*`: repo-owned WebKit source changes applied to downstream checkouts.
- `patches/common`: patches applied to every source tree when applicable.
- `patches/android`: Android/WPE Android specific patches.
- `patches/windows`: Windows specific patches.
- `platforms/*`: setup and build entry points per platform.
- `scripts`: shared patch, artifact, and build helpers.
- `service`: local HTTP API for starting, restarting, checkpointing, and tracking builds.

The quality bar for security-critical browser work is recorded in
[`constitution.md`](./constitution.md). Keep portable policy in `src/ng/browser`;
put WebKit integration patches in `changes/*`; keep platform build mechanics in
`platforms/*` and `patches/*`.

Patch files should be standard `git format-patch` or `git diff` patches with `.patch`
or `.diff` suffixes. The build scripts apply `patches/common` first, then the platform
patch directory.

## Central WebKit Changes

Put product changes in `changes/<change-id>`, not directly in platform scripts. Enable
them in `config/changes.json`. Every target applies enabled changes before its
platform build starts.

```bash
./scripts/new-change.sh passkeys-credentials-get
```

For example, a passkey change to `navigator.credentials.get` would usually start as a
WebCore patch in `changes/passkeys-credentials-get/patches/common`, with any Android
or Windows build fixes beside it in `patches/android` or `patches/windows`.

Windows WebGPU runtime service work belongs in
`changes/windows-webgpu-service`, not in generic Windows compiler/build patches.
Enable it in `config/changes.json` only for builds intended to validate the
custom service path.

Windows WebGPU/Dawn repeatability notes live in
[`platforms/windows/webgpu-dawn-runbook.md`](./platforms/windows/webgpu-dawn-runbook.md).

For the current Windows WebGPU runtime investigation, use:

```bash
NG_WINDOWS_SOURCE_PRESET=iangrunert-win-gigacage-skia-fixes \
NG_WINDOWS_ENABLE_WEBGPU=1 \
./scripts/run-build.sh windows <build-id>
```

That preset points the reproducible Windows checkout at
`iangrunert/WebKit@64f58084c78130b874d05dbcfb508147354095af`.

## Dependencies

Dependencies are cataloged in `config/dependencies.json` and build-machine placement is
defined in `config/build-machines.json`.

```bash
./scripts/catalog-deps.sh
NG_DEPS_UPLOAD=1 ./scripts/catalog-deps.sh
./scripts/ship-deps.sh android
./scripts/ship-deps.sh windows
```

The catalog records file size and SHA-256 for local dependency artifacts, and the
shipping script copies local dependencies or syncs S3 prefixes to the target machine.

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
